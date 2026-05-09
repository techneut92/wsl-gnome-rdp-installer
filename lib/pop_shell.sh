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
    log "Skipping Pop Shell install (INSTALL_POP_SHELL=0)."
    return 0
  fi

  log "Installing Pop Shell tiling extension…"

  # Idempotent fetch: clone if missing, otherwise pull master to head.
  mkdir -p "$(dirname "$POP_SHELL_SRC")"
  if [ -d "$POP_SHELL_SRC/.git" ]; then
    git -C "$POP_SHELL_SRC" fetch --depth=1 origin master >/dev/null 2>&1
    git -C "$POP_SHELL_SRC" reset --hard origin/master >/dev/null
  else
    git clone --depth=1 "$POP_SHELL_REPO" "$POP_SHELL_SRC" >/dev/null 2>&1
  fi

  # configure.sh prompts interactively to confirm the keybinding override.
  # Touching this file makes configure.sh accept defaults non-interactively;
  # without it the script prints "Cancelled" and skips dconf setup, leaving
  # Pop Shell installed but with no keybindings wired up.
  touch "$POP_SHELL_SRC/.confirm_shortcut_change"

  # WAYLAND_DISPLAY is set in our environment, so the Makefile's
  # `restart-shell` step prints "WAYLAND_DISPLAY is set, not restarting
  # shell" and skips. That's correct — gnome-shell on Wayland can't restart
  # in place. We rely on install_systemd_units having already started a
  # fresh gnome-shell that will pick up the new extension.
  make -C "$POP_SHELL_SRC" local-install 2>&1 | tail -20

  # Verify gnome-shell sees + enabled the extension. `make local-install`
  # ends with `gnome-extensions enable`; if that fails (e.g. shell not yet
  # running) the make target errors out — but we still want the extension
  # ready for the next gnome-shell start, so re-attempt enable here.
  if gnome-extensions list 2>/dev/null | grep -qx "$POP_SHELL_UUID"; then
    gnome-extensions enable "$POP_SHELL_UUID" 2>/dev/null || true
    if gnome-extensions info "$POP_SHELL_UUID" 2>/dev/null | grep -q '^[[:space:]]*Enabled: Yes'; then
      log "Pop Shell installed and enabled."
    else
      warn "Pop Shell installed but not enabled — try 'gnome-extensions enable $POP_SHELL_UUID' after a fresh gnome-shell."
    fi
  else
    warn "Pop Shell built but gnome-shell hasn't picked it up. It will load on the next gnome-shell start."
  fi
}
