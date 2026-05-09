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
  # The trailing `gnome-extensions enable` ALWAYS fails on first install
  # under Wayland — gnome-shell can't be restarted without dropping the
  # session, so it never rescans the extensions dir, and `enable` 5xxs
  # against an "extension does not exist" error. The recovery path below
  # (restart gnome-shell-headless, then enable explicitly) handles it.
  #
  # We can't use ui_spin around make: it'd render ✗ on the expected
  # partial failure. Instead, manage the spinner ourselves and downgrade
  # to ⚠ (with the recovery hint) when the post-install check shows the
  # extension files were staged successfully — a real make failure
  # (no metadata.json) still renders ✗.
  ui_step "Build + local-install"
  local make_log; make_log=$(mktemp)
  local make_rc=0
  make -C "$POP_SHELL_SRC" local-install >"$make_log" 2>&1 &
  local make_pid=$!
  local i=0 char
  while kill -0 "$make_pid" 2>/dev/null; do
    char="${_UI_SPIN_CHARS:$i:1}"
    printf '\r  %s%s%s Build + local-install\033[K' \
      "$UI_BOLD$UI_BLUE" "$char" "$UI_RESET" >/dev/tty 2>/dev/null || break
    i=$(( (i + 1) % ${#_UI_SPIN_CHARS} ))
    sleep 0.1
  done
  wait "$make_pid" || make_rc=$?

  local meta="$HOME/.local/share/gnome-shell/extensions/$POP_SHELL_UUID/metadata.json"
  if [ "$make_rc" -eq 0 ]; then
    printf '\r  %s✓%s Build + local-install\033[K\n' "$UI_GREEN" "$UI_RESET"
  elif [ -f "$meta" ]; then
    # `make local-install` on Wayland always trails with a failed
    # `gnome-extensions enable` (no usable dbus connection from the
    # make recipe). The build itself succeeded — extension files are
    # staged. We re-attempt enable after restarting gnome-shell-headless
    # below. Mark this step ✓; the recovery surfaces its own status.
    printf '\r  %s✓%s Build + local-install\033[K\n' "$UI_GREEN" "$UI_RESET"
  else
    printf '\r  %s✗%s Build + local-install\033[K\n' "$UI_RED" "$UI_RESET"
    tail -10 "$make_log" 2>/dev/null | sed 's/^/    /' >&2
    rm -f "$make_log"
    return 1
  fi
  rm -f "$make_log"

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
