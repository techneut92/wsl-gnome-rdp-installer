#!/usr/bin/env bash
# install.sh — set up a headless GNOME desktop on WSL2, accessible via RDP.
#
# Architecture:
#   gnome-shell --headless --mode=user      (Wayland compositor + GNOME UI)
#       └── exposes org.gnome.Mutter.RemoteDesktop on the user session bus
#   gnome-remote-desktop-daemon --headless  (FreeRDP listener on RDP_PORT)
#       └── env-forced software EGL because WSL2's dzn (DX→Vulkan) Mesa stack
#           segfaults inside grd_egl_thread_new on the hardware path.
#
# Runs as a user-level systemd unit (no GDM, no system service). Lingering is
# enabled so the desktop survives shell logout.

set -euo pipefail

# ---------- Defaults (overridable via flags or env) ----------
RDP_PORT="${RDP_PORT:-3390}"            # 3389 is owned by Windows host RDP
RDP_USERNAME="${RDP_USERNAME:-}"
RDP_PASSWORD="${RDP_PASSWORD:-}"
TLS_DIR="${TLS_DIR:-$HOME/.local/share/gnome-remote-desktop}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

usage() {
  cat <<EOF
Usage: $0 [-u USERNAME] [-p PASSWORD] [-P PORT] [-m]
  -u USERNAME    RDP login username  (default: prompt; reused on re-run)
  -p PASSWORD    RDP login password  (default: prompt; reused on re-run)
  -P PORT        RDP listen port     (default: $RDP_PORT)
  -m             minimal: pre-uncheck full GNOME desktop + per-flatpak
                 boxes in the component menu (still adjustable via menu)
  -h             show this help

The component selection menu (GNOME desktop apps, Firefox flatpak,
ONLYOFFICE flatpak, Pop Shell, custom kernel for /dev/dri/renderD128)
opens at the start of the run. Pre-set any of these via env to skip
the default and arrive at the menu with the corresponding box
pre-checked/unchecked:

  INSTALL_DESKTOP=0/1       INSTALL_FIREFOX=0/1
  INSTALL_ONLYOFFICE=0/1    INSTALL_POP_SHELL=0/1
  INSTALL_RENDERD=0/1

AppIndicator extension is mandatory (always installed) — needed for
tray-icon apps like jetbrains-toolbox.
EOF
}

while getopts ":u:p:P:mh" opt; do
  case "$opt" in
    u) RDP_USERNAME="$OPTARG" ;;
    p) RDP_PASSWORD="$OPTARG" ;;
    P) RDP_PORT="$OPTARG" ;;
    # -m: pre-uncheck the GNOME desktop + every flatpak box. User can
    # still re-check anything in the menu.
    m) INSTALL_DESKTOP=0; INSTALL_FIREFOX=0; INSTALL_ONLYOFFICE=0 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
export RDP_PORT RDP_USERNAME RDP_PASSWORD TLS_DIR SYSTEMD_USER_DIR

# ---------- Resolve the project root and pull in helpers ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT

# shellcheck source=lib/ui.sh
. "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=lib/common.sh
. "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/packages.sh
. "$PROJECT_ROOT/lib/packages.sh"
# shellcheck source=lib/dbus.sh
. "$PROJECT_ROOT/lib/dbus.sh"
# shellcheck source=lib/cgroup_collision.sh
. "$PROJECT_ROOT/lib/cgroup_collision.sh"
# shellcheck source=lib/cert.sh
. "$PROJECT_ROOT/lib/cert.sh"
# shellcheck source=lib/configure.sh
. "$PROJECT_ROOT/lib/configure.sh"
# shellcheck source=lib/verify.sh
. "$PROJECT_ROOT/lib/verify.sh"
# shellcheck source=lib/pop_shell.sh
. "$PROJECT_ROOT/lib/pop_shell.sh"
# shellcheck source=lib/renderd_kernel.sh
. "$PROJECT_ROOT/lib/renderd_kernel.sh"
# shellcheck source=lib/qol_bootstrap.sh
. "$PROJECT_ROOT/lib/qol_bootstrap.sh"
# shellcheck source=lib/prompt.sh
. "$PROJECT_ROOT/lib/prompt.sh"

# ---------- Sanity ----------
[ "$EUID" -eq 0 ] && die "Run as your normal user, not root. Sudo is used internally where needed."
grep -qi microsoft /proc/version || warn "Not running under WSL? Continuing anyway."
# Runtime check only — /run/systemd/system exists iff systemd is PID 1 and
# initialised. Don't parse /etc/wsl.conf: that's the user's responsibility,
# we just verify the live state and tell them what to do if it's wrong.
[ -d /run/systemd/system ] || die "systemd is not running in this distro. Enable it (add [boot]\nsystemd=true to /etc/wsl.conf), then 'wsl --shutdown' from Windows and retry."

# ---------- Self-update from upstream -------------------------------
# If $PROJECT_ROOT is a git checkout with an upstream tracking branch,
# fetch + fast-forward to origin's HEAD before running, then re-exec.
# Skipped on:
#   - no .git
#   - no upstream tracking branch (fork without `git push -u`)
#   - dirty working tree (preserves WIP — RESET_DIRTY=1 to clobber)
#   - fetch/auth failure (offline or no creds — warn, continue)
#   - non-FF (divergent local commits — warn, continue)
#   - _WSL_RDP_SELF_UPDATED=1 (set on re-exec so we don't loop)
#
# RESET_DIRTY=1: do `git reset --hard HEAD` before pulling. The
# wsl-rdp-gnome-renew shim sets this by default — invoking renew
# explicitly means "give me upstream". On the first-time clone path
# we don't reset, so a developer hacking on install.sh locally
# doesn't get clobbered.
self_update() {
  [ "${_WSL_RDP_SELF_UPDATED:-0}" = "1" ] && return 0
  [ -d "$PROJECT_ROOT/.git" ] || return 0

  ui_step "self-update"

  local upstream
  upstream=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || true
  if [ -z "$upstream" ]; then
    ui_skip "no upstream tracking branch"
    return 0
  fi

  # Refresh the index so files whose mtimes changed but contents
  # didn't (common after tar-extract / clone-with-checkout-perms-
  # tweak) don't show up as spurious dirty entries below.
  git -C "$PROJECT_ROOT" update-index --really-refresh >/dev/null 2>&1 || true

  if ! git -C "$PROJECT_ROOT" diff-index --quiet HEAD -- 2>/dev/null; then
    if [ "${RESET_DIRTY:-0}" = "1" ]; then
      ui_spin "Working tree dirty — reset --hard HEAD" \
        git -C "$PROJECT_ROOT" reset --hard --quiet HEAD
    else
      ui_skip "working tree dirty — pull skipped"
      ui_detail "first 5 changed paths:"
      git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null \
        | head -5 | sed 's/^/    /'
      ui_detail "RESET_DIRTY=1 to clobber + pull, or wsl-rdp-gnome-renew"
      return 0
    fi
  fi

  if ! ui_spin "Fetch from $upstream" \
        git -C "$PROJECT_ROOT" fetch --quiet; then
    ui_warn "fetch failed (offline / no auth) — continuing with current"
    return 0
  fi

  local local_sha upstream_sha
  local_sha=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null) || return 0
  upstream_sha=$(git -C "$PROJECT_ROOT" rev-parse "$upstream" 2>/dev/null) || return 0

  if [ "$local_sha" = "$upstream_sha" ]; then
    ui_ok "Already at $upstream"
    ui_detail "${local_sha:0:7}"
    return 0
  fi

  if ui_spin "Pull ${local_sha:0:7} → ${upstream_sha:0:7}" \
       git -C "$PROJECT_ROOT" pull --ff-only --quiet; then
    ui_detail "re-executing updated install.sh…"
    export _WSL_RDP_SELF_UPDATED=1
    exec "$PROJECT_ROOT/install.sh" "$@"
  else
    ui_warn "pull failed (non-FF or conflict) — continuing with current"
  fi
}

# ---------- /usr/local/bin/wsl-rdp-gnome-renew shim -----------------
# Drop a renew shim early so even if a later step fails, re-running is
# one command from anywhere — no need to remember $PROJECT_ROOT.
# Always overwritten so the shim's contents track the current install
# location.
install_renew_shim() {
  ui_step "renew shim"
  local shim=/usr/local/bin/wsl-rdp-gnome-renew
  sudo tee "$shim" >/dev/null <<EOF
#!/usr/bin/env bash
# Generated by wsl-gnome-rdp-installer's install.sh — do not edit by hand.
# Re-runs install.sh from the stable install location ($PROJECT_ROOT).
# install.sh self-updates from its git origin first. RESET_DIRTY=1
# means "I invoked renew, so any stray local edits get clobbered
# before the pull" — different from the first-time install path,
# which preserves WIP.
exec env RESET_DIRTY=1 "$PROJECT_ROOT/install.sh" "\$@"
EOF
  sudo chmod 0755 "$shim"
  ui_ok "Install $shim"
  ui_detail "→ $PROJECT_ROOT/install.sh (RESET_DIRTY=1)"
}

# ---------- Stable install location ---------------------------------
# Copy the running checkout to a stable per-user location so the renew
# shim doesn't depend on wherever the user happens to keep their
# clone. INSTALL_DIR follows XDG_DATA_HOME convention (~/.local/share).
# Override with WSL_RDP_INSTALL_DIR.
#
# On the first run from a clone:
#   1. self_update fetches+pulls in the user's clone (so origin auth
#      uses their identity).
#   2. We rsync the clone (with .git intact) into INSTALL_DIR.
#   3. We re-exec install.sh from INSTALL_DIR — _WSL_RDP_BOOTSTRAPPED=1
#      so we don't loop.
# Subsequent renew-shim runs:
#   - PROJECT_ROOT == INSTALL_DIR. self_update pulls in INSTALL_DIR,
#     bootstrap is a no-op, pipeline runs.
INSTALL_DIR="${WSL_RDP_INSTALL_DIR:-$HOME/.local/share/wsl-gnome-rdp-installer}"

self_update "$@"

if [ "$PROJECT_ROOT" != "$INSTALL_DIR" ] \
   && [ "${_WSL_RDP_BOOTSTRAPPED:-0}" != "1" ]; then
  ui_step "bootstrap to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  if command -v rsync >/dev/null 2>&1; then
    ui_spin "Sync $PROJECT_ROOT → $INSTALL_DIR" \
      rsync -a --delete --exclude='.idea' --exclude='.vscode' \
        "$PROJECT_ROOT/" "$INSTALL_DIR/"
  else
    ui_spin "Copy $PROJECT_ROOT → $INSTALL_DIR (cp fallback)" bash -c "
      rm -rf '$INSTALL_DIR'
      cp -a '$PROJECT_ROOT' '$INSTALL_DIR'
      rm -rf '$INSTALL_DIR/.idea' '$INSTALL_DIR/.vscode'
    "
  fi
  # Re-exec from INSTALL_DIR so PROJECT_ROOT — and the renew shim's
  # baked-in path — point at the stable location, not the user's clone.
  ui_detail "re-executing from $INSTALL_DIR…"
  export _WSL_RDP_BOOTSTRAPPED=1 _WSL_RDP_SELF_UPDATED=1
  exec "$INSTALL_DIR/install.sh" "$@"
fi

# ---------- Pipeline ----------
install_renew_shim
ui_phase "Preflight"
detect_distro                      # sets DISTRO_FAMILY, DISTRO_ID, DISTRO_VERSION
ui_ok    "Detect distro"
ui_detail "$DISTRO_ID ($DISTRO_FAMILY)"

# Multi-distro cgroup-collision check FIRST — if another running WSL2
# distro owns /user.slice/user-$UID.slice/user@$UID.service/, no amount
# of single-distro fixes (drop-ins, restarts) will help. Detect, prompt
# the user (renumber UID / shut down other distro / continue anyway),
# and stage a renumber unit if asked.
precheck_cgroup_collision

# Cgroup precheck SECOND — handle the single-distro variant (systemd
# #41278): install the drop-in and prove user@$UID.service can start,
# so we don't waste a 30-60s package install on a box that needs
# `wsl --shutdown` before anything else can succeed.
precheck_user_at_service           # installs drop-in + start probe

# Ask everything upfront — credentials + which optional components to
# install. Keeps the rest of the run uninterrupted. Sets RDP_USERNAME,
# RDP_PASSWORD, REUSE_CREDS, INSTALL_DESKTOP, INSTALL_FLATPAK,
# INSTALL_POP_SHELL, INSTALL_APPINDICATOR, INSTALL_RENDERD.
prompt_all_settings

# Run wsl-qol first — owns the desktop-agnostic fixes (binfmt drop-in,
# flatpak Start-Menu auto-publish, theme sync, WSLg pulse-detach,
# flatpak base remotes + global overrides). The .path watcher it
# installs needs to be live before install_flatpak_apps modifies the
# flatpak exports dir, and the /tmp deny override needs to apply
# before ONLYOFFICE is launched the first time.
bootstrap_wsl_qol

ui_phase "Host setup"
install_packages                   # uses DISTRO_FAMILY + INSTALL_DESKTOP/INSTALL_FLATPAK
# Kernel modules (vgem+vkms) up front, alongside packages, so /dev/dri
# is fully populated before gnome-shell-headless first starts and so
# the video+render group additions land before lingering kicks user
# services off in their long-lived form. Cheap on the happy path
# (~5–10s prebuilt download), bounded on the cold path (~60–90s local
# build) — the prompt warned the user about the cold path up-front.
[ "${INSTALL_RENDERD:-0}" = "1" ] && install_renderd_kernel
enable_lingering                   # safe now: user@$UID.service is healthy
ensure_user_dbus                   # /run/user setup + dbus polling

ui_phase "RDP services"
ensure_tls_cert                    # winpr-makecert if available, else openssl
configure_grd                      # grdctl --headless settings
install_user_environment           # ~/.config/environment.d/*.conf
install_xdg_user_dirs              # ~/Downloads, ~/Documents, ~/Pictures, … (xdg-user-dirs-update)
install_default_wallpaper          # /usr/share/backgrounds/pane-wallpaper.jpg + gsettings (first-install only)
apply_theme_sync                   # re-fire post-packages so gsettings tier lands (wsl-qol's bootstrap fires too early)
[ "${INSTALL_APPINDICATOR:-1}" = "1" ] && enable_appindicator_extension
install_x11_unix_fix               # /etc/systemd/system/wslg-x11-unix-fix.service
install_systemd_units              # write + enable + restart
[ "${INSTALL_POP_SHELL:-1}" = "1" ] && install_pop_shell

ui_phase "Verification"
verify_and_print_summary

# vim: set ts=2 sw=2 et:
