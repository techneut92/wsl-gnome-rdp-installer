# lib/dbus.sh — bootstrap the user systemd manager + dbus session.
#
# On a fresh WSL distro, `wsl -d <distro>` typically spawns bash via init
# (not via PAM), so user@$UID.service never starts and /run/user/$UID/bus
# never appears. enable-linger alone doesn't always trigger a start during
# the same shell. We force-start user@.service with sudo, then poll for
# the bus socket.

# Drop-in path for the systemd 259 cgroup workaround (see apply_user_at_workaround).
USER_AT_DROPIN_DIR="/etc/systemd/system/user@.service.d"
USER_AT_DROPIN_FILE="$USER_AT_DROPIN_DIR/99-wsl-cgroup-fix.conf"

# Workaround for systemd issue #41278 (fixed by PR #41304, milestone v261).
# On systemd 259 — shipped by Fedora 44 — Delegate=yes services hit EBUSY
# on sd-executor's clone3(CLONE_INTO_CGROUP) because stale subtree_control
# entries violate cgroup v2's "no internal processes" rule. user@.service
# is Delegate=yes by default, so it fails to start with:
#   user@$UID.service: Failed to spawn executor: Device or resource busy
# Clearing DelegateSubgroup= sidesteps the migration into the inner
# init.scope cgroup that triggers the kernel's EBUSY.
#
# Once Fedora rebases to systemd >= 261 this drop-in becomes a no-op and
# can be removed.
apply_user_at_workaround() {
  if [ -f "$USER_AT_DROPIN_FILE" ] \
     && grep -q '^DelegateSubgroup=$' "$USER_AT_DROPIN_FILE" 2>/dev/null; then
    ui_skip "user@.service drop-in already in place"
    return 0
  fi
  sudo install -d -m 755 "$USER_AT_DROPIN_DIR"
  sudo tee "$USER_AT_DROPIN_FILE" >/dev/null <<'EOF'
# Workaround for systemd issue #41278 (fixed in PR #41304, v261).
# On systemd 259, Delegate=yes services hit EBUSY in sd-executor's
# clone3(CLONE_INTO_CGROUP) because of stale subtree_control entries.
# Clearing DelegateSubgroup keeps the user manager directly in
# user@$UID.service's cgroup, avoiding the inner-cgroup migration.
[Service]
DelegateSubgroup=
EOF
  ui_spin "Install user@.service drop-in + reload" \
    sudo systemctl daemon-reload
  ui_detail "$USER_AT_DROPIN_FILE"
}

# Cheap up-front check: install the drop-in, then prove user@$UID.service
# can start. Called at the very top of the installer so that a fresh-boot
# dirty-cgroup state aborts in ~1s, before any package install runs.
# A fresh WSL distro often has user@.service tried (and failed) by some
# system path before our script runs — that failure dirties the cgroup,
# and the dirty state survives our drop-in install. Only `wsl --shutdown`
# clears it. Re-running after the shutdown finds the drop-in already on
# disk, so the start succeeds first try.
precheck_user_at_service() {
  local UID_NUM
  UID_NUM=$(id -u)

  ui_step "user@$UID_NUM.service"
  apply_user_at_workaround

  if systemctl is-active --quiet "user@$UID_NUM.service" 2>/dev/null; then
    ui_ok "already active"
    return 0
  fi

  sudo systemctl reset-failed "user@$UID_NUM.service" 2>/dev/null || true
  if ! ui_spin "Start user@$UID_NUM.service" \
        sudo systemctl start "user@$UID_NUM.service"; then
    die "user@$UID_NUM.service failed to start. The cgroup is likely already
       dirtied by a prior failed start on this boot — orphaned subgroups
       under /sys/fs/cgroup/user.slice/user-$UID_NUM.slice/user@$UID_NUM.service/
       cannot be cleaned up without rebooting WSL.

       Fix: run 'wsl.exe --shutdown' from Windows, reopen WSL, and re-run
       this installer. The drop-in this script just installed (at
       $USER_AT_DROPIN_FILE) will let user@$UID_NUM.service start
       cleanly on the next boot."
  fi
}

ensure_user_dbus() {
  local UID_NUM
  UID_NUM=$(id -u)
  local DBUS_SOCK="/run/user/$UID_NUM/bus"

  ui_step "User D-Bus"

  # 1. /run/user/$UID may not exist yet. Create it if missing.
  if [ ! -d "/run/user/$UID_NUM" ]; then
    sudo install -d -m 700 -o "$USER" -g "$USER" "/run/user/$UID_NUM"
    ui_ok "Create /run/user/$UID_NUM"
  fi
  export XDG_RUNTIME_DIR="/run/user/$UID_NUM"

  # 2. user@$UID.service is already running — precheck_user_at_service ran
  #    at the top of install.sh and would have aborted otherwise.

  # 4. Set DBUS_SESSION_BUS_ADDRESS for non-login bash shells in WSL.
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$DBUS_SOCK"
  fi

  # 5. Poke dbus.socket / dbus.service in case they didn't auto-start.
  systemctl --user start dbus.socket dbus.service 2>/dev/null || true

  # 6. Wait for the bus to be reachable.
  ui_spin "Wait for $DBUS_SOCK (≤30s)" bash -c '
    for i in $(seq 1 30); do
      if [ -S "'"$DBUS_SOCK"'" ] && busctl --user --no-pager list >/dev/null 2>&1; then
        exit 0
      fi
      sleep 1
    done
    exit 1
  ' || die "User D-Bus didn't come up after 30s. Try: 'wsl --shutdown' on Windows, then re-enter and re-run."
}
