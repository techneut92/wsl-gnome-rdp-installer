# lib/pop_shell.sh — install the Pop!_OS Pop Shell tiling extension.
#
# Pop Shell is a keyboard-driven tiling layer for GNOME Shell maintained
# by System76. It's not packaged for Fedora 44 (and the Debian package
# tends to lag), so we build from source. The Makefile's `local-install`
# target runs depcheck + compile + install + configure + restart-shell
# (no-op on Wayland) + enable.
#
# Called AFTER install_systemd_units so gnome-shell-headless is up — the
# `gnome-extensions enable` step at the end of `make local-install` talks
# to org.gnome.Shell.Extensions over the user dbus, which requires the
# shell to be running.

POP_SHELL_REPO="${POP_SHELL_REPO:-https://github.com/pop-os/shell.git}"
POP_SHELL_SRC="${POP_SHELL_SRC:-$HOME/src/pop-shell}"
POP_SHELL_UUID="pop-shell@system76.com"

install_pop_shell() {
  if [ "${INSTALL_POP_SHELL:-1}" != "1" ]; then
    ui_step "Pop Shell"
    ui_skip "INSTALL_POP_SHELL=0"
    return 0
  fi

  ui_step "Pop Shell tiling extension"

  # Idempotent fetch: clone if missing, otherwise pull the upstream
  # default branch to HEAD. As of 2026, pop-os/shell publishes per-LTS
  # branches (master_noble, master_jammy, …) with HEAD pointing at the
  # newest — there's no plain `master` anymore. Resolve HEAD's symref
  # remotely and use whatever name upstream is currently calling default,
  # so this keeps working when pop-os adds master_<next-lts>.
  mkdir -p "$(dirname "$POP_SHELL_SRC")"
  local pop_branch
  pop_branch=$(git ls-remote --symref "$POP_SHELL_REPO" HEAD 2>/dev/null \
                 | awk '/^ref: /{ sub("refs/heads/", "", $2); print $2; exit }')
  if [ -z "$pop_branch" ]; then
    ui_warn "Couldn't resolve pop-os/shell default branch — falling back to master_noble"
    pop_branch="master_noble"
  fi

  if [ -d "$POP_SHELL_SRC/.git" ]; then
    # Explicit refspec — the existing clone may have a stale
    # remote.origin.fetch glob (from when upstream's default was
    # `master`), so a bare `fetch origin <branch>` doesn't always
    # create the matching remote-tracking ref. The `<src>:<dst>` form
    # forces it.
    ui_spin "Update source ($POP_SHELL_SRC, branch $pop_branch)" bash -c '
      set -e
      git -C "'"$POP_SHELL_SRC"'" fetch --depth=1 origin \
        "'"$pop_branch"':refs/remotes/origin/'"$pop_branch"'"
      git -C "'"$POP_SHELL_SRC"'" reset --hard "origin/'"$pop_branch"'"
    '
  else
    ui_spin "Clone $POP_SHELL_REPO ($pop_branch)" \
      git clone --depth=1 --branch "$pop_branch" "$POP_SHELL_REPO" "$POP_SHELL_SRC"
  fi

  # configure.sh prompts interactively to confirm the keybinding override.
  # Touching this file makes configure.sh accept defaults non-interactively;
  # without it the script prints "Cancelled" and skips dconf setup, leaving
  # Pop Shell installed but with no keybindings wired up.
  touch "$POP_SHELL_SRC/.confirm_shortcut_change"

  # `make local-install` does: depcheck → compile → install (copies into
  # ~/.local/share/gnome-shell/extensions/) → configure (dconf writes) →
  # restart-shell (no-op on Wayland) → enable.
  #
  # The trailing `gnome-extensions enable` will FAIL when gnome-shell was
  # already running before this step (it doesn't auto-rescan the extensions
  # dir). ui_spin returns the command's exit code; we want to keep going
  # regardless because we recover below by bouncing gnome-shell. Wrap in
  # `|| true` so a non-zero exit doesn't abort install.sh under set -e.
  ui_spin "Build + local-install" \
    make -C "$POP_SHELL_SRC" local-install || true

  # Bounce gnome-shell so it rescans the extensions dir and registers Pop
  # Shell. grd's Requires=gnome-shell-headless means systemd will stop grd
  # too — restart it after gnome-shell is back. Drops any in-progress RDP
  # session, but the installer's running in a pts shell, not RDP.
  if systemctl --user is-active --quiet gnome-shell-headless.service; then
    ui_spin "Restart gnome-shell-headless to pick up Pop Shell" bash -c '
      set -e
      systemctl --user restart gnome-shell-headless.service
      for i in $(seq 1 15); do
        if gnome-extensions list 2>/dev/null | grep -qx "'"$POP_SHELL_UUID"'"; then
          break
        fi
        sleep 1
      done
      systemctl --user restart gnome-remote-desktop-headless.service 2>/dev/null || true
    '
  fi

  if gnome-extensions list 2>/dev/null | grep -qx "$POP_SHELL_UUID"; then
    gnome-extensions enable "$POP_SHELL_UUID" 2>/dev/null || true
    if gnome-extensions info "$POP_SHELL_UUID" 2>/dev/null | grep -q '^[[:space:]]*Enabled: Yes'; then
      ui_ok "Pop Shell enabled"
    else
      ui_warn "Pop Shell installed but not enabled"
      ui_detail "try 'gnome-extensions enable $POP_SHELL_UUID' after a fresh gnome-shell"
    fi
  else
    ui_warn "Pop Shell built but gnome-shell hasn't picked it up"
    ui_detail "it will load on the next gnome-shell start"
  fi
}
