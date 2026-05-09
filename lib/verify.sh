# lib/verify.sh — final state check + connection summary.

verify_and_print_summary() {
  sleep 3
  local SHELL_OK GRD_OK LISTEN WSL_IP RENDERER
  SHELL_OK=$(systemctl --user is-active gnome-shell-headless.service || true)
  GRD_OK=$(systemctl --user is-active gnome-remote-desktop-headless.service || true)
  # `|| true` on every pipe — set -o pipefail (from install.sh) would
  # otherwise propagate `grep`-no-match (exit 1) or any single-stage
  # failure into the assignment, and set -e then kills the script
  # silently before any of these diagnostic vars are even consumed.
  LISTEN=$(ss -tln 2>/dev/null | awk -v p=":$RDP_PORT" '$0~p{found=1} END{print found+0}' || true)
  WSL_IP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || echo "?")

  # Mutter logs "Created surfaceless renderer with GPU" (hardware) or
  # "without GPU" (llvmpipe). Cogl also logs the OpenGL renderer string.
  # Pull whichever appeared most recently from the last 30s of journal.
  RENDERER=$(journalctl --user -u gnome-shell-headless.service \
                        --since '30 seconds ago' --no-pager 2>/dev/null \
             | grep -iE 'surfaceless renderer|GL renderer|OpenGL renderer' \
             | tail -1 || true)

  # Two parameter expansions concatenated would EMIT THE PASSWORD if
  # RDP_PASSWORD was set — `${var:+REPLACE}${var:-DEFAULT}` resolves to
  # `REPLACE` + `<value>`, not the XOR the original author meant.
  # Compute a single status string here.
  local pw_status
  if [ -n "$RDP_PASSWORD" ]; then
    pw_status="(the one you provided)"
  else
    pw_status="(unchanged from previous run)"
  fi

  if [ "$SHELL_OK" != "active" ] || [ "$GRD_OK" != "active" ] || [ "$LISTEN" -lt 1 ]; then
    warn "Setup didn't come up cleanly:"
    warn "  gnome-shell-headless: $SHELL_OK"
    warn "  gnome-remote-desktop-headless: $GRD_OK"
    warn "  port $RDP_PORT listening: $LISTEN"
    warn "Inspect with:"
    warn "  systemctl --user status gnome-shell-headless.service gnome-remote-desktop-headless.service"
    warn "  journalctl --user -u gnome-shell-headless.service -u gnome-remote-desktop-headless.service -n 100"
    exit 1
  fi

  # Did this run modify supplementary groups (renderd added video+render)?
  # If so, the user's existing wsl shell + already-running user@$UID.service
  # don't have them yet. A fresh logind session is the only way to refresh
  # — `wsl -t <distro>` from Windows is the cleanest path.
  local groups_hint=""
  if [ "${RENDERD_GROUPS_ADDED:-0}" = "1" ]; then
    local distro
    distro=$(awk -F= '$1=="WSL_DISTRO_NAME" {print $2}' /proc/$$/environ 2>/dev/null \
             | tr -d '\0' \
             | head -1)
    [ -z "$distro" ] && distro=$(printenv WSL_DISTRO_NAME 2>/dev/null)
    [ -z "$distro" ] && distro="<distro>"
    groups_hint=$(cat <<EOH

  ⚠ video + render group added to $USER — required for /dev/dri/*
    To pick it up: from a Windows shell, run  wsl -t $distro
    Then reopen WSL and re-mstsc.
EOH
)
  fi

  cat <<EOF

================================================================
  GNOME RDP is up and listening on port $RDP_PORT
================================================================
  Compositor renderer (mutter):
    ${RENDERER:-(no renderer line yet — check journal in a moment)}

  From Windows host:
    Single monitor:   mstsc /v:localhost:$RDP_PORT
    Multi-monitor:    mstsc /v:localhost:$RDP_PORT /multimon
    (or use $WSL_IP:$RDP_PORT if localhost forwarding isn't on)

  RDP credentials:
    Username:  ${RDP_USERNAME:-(unchanged from previous run)}
    Password:  $pw_status

  Service control:
    systemctl --user {status,restart,stop} gnome-shell-headless.service
    systemctl --user {status,restart,stop} gnome-remote-desktop-headless.service

  Logs:
    journalctl --user -u gnome-shell-headless.service -f
    journalctl --user -u gnome-remote-desktop-headless.service -f
$groups_hint
  Re-run install.sh any time to update the config / credentials.
================================================================
EOF
}
