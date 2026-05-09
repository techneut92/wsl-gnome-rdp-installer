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
INSTALL_DESKTOP="${INSTALL_DESKTOP:-1}" # 1 = pull in the full GNOME desktop group (Files, terminal, etc.)

usage() {
  cat <<EOF
Usage: $0 [-u USERNAME] [-p PASSWORD] [-P PORT] [-m]
  -u USERNAME    RDP login username  (default: prompt; reused on re-run)
  -p PASSWORD    RDP login password  (default: prompt; reused on re-run)
  -P PORT        RDP listen port     (default: $RDP_PORT)
  -m             minimal: skip the full GNOME desktop group (headless shell only)
  -h             show this help

Env vars: RDP_USERNAME, RDP_PASSWORD, RDP_PORT, TLS_DIR, SYSTEMD_USER_DIR, INSTALL_DESKTOP
EOF
}

while getopts ":u:p:P:mh" opt; do
  case "$opt" in
    u) RDP_USERNAME="$OPTARG" ;;
    p) RDP_PASSWORD="$OPTARG" ;;
    P) RDP_PORT="$OPTARG" ;;
    m) INSTALL_DESKTOP=0 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
export RDP_PORT RDP_USERNAME RDP_PASSWORD TLS_DIR SYSTEMD_USER_DIR INSTALL_DESKTOP

# ---------- Resolve the project root and pull in helpers ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT

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

# ---------- Sanity ----------
[ "$EUID" -eq 0 ] && die "Run as your normal user, not root. Sudo is used internally where needed."
grep -qi microsoft /proc/version || warn "Not running under WSL? Continuing anyway."
# Runtime check only — /run/systemd/system exists iff systemd is PID 1 and
# initialised. Don't parse /etc/wsl.conf: that's the user's responsibility,
# we just verify the live state and tell them what to do if it's wrong.
[ -d /run/systemd/system ] || die "systemd is not running in this distro. Enable it (add [boot]\nsystemd=true to /etc/wsl.conf), then 'wsl --shutdown' from Windows and retry."

# ---------- Pipeline ----------
detect_distro                      # sets DISTRO_FAMILY, DISTRO_ID, DISTRO_VERSION
log "Distro: $DISTRO_ID ($DISTRO_FAMILY)"

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

install_packages                   # uses DISTRO_FAMILY
enable_lingering                   # safe now: user@$UID.service is healthy
ensure_user_dbus                   # /run/user setup + dbus polling
prompt_credentials
ensure_tls_cert                    # winpr-makecert if available, else openssl
configure_grd                      # grdctl --headless settings
install_user_environment           # ~/.config/environment.d/*.conf
enable_appindicator_extension      # tray support for jetbrains-toolbox & friends
configure_wallpaper                # bypass Fedora's missing JXL pixbuf loader
install_x11_unix_fix               # /etc/systemd/system/wslg-x11-unix-fix.service
install_systemd_units              # write + enable + restart
install_pop_shell                  # build + enable Pop Shell tiling extension
verify_and_print_summary

# vim: set ts=2 sw=2 et:
