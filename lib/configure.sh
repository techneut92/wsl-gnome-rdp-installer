# lib/configure.sh — grdctl settings + systemd user units.

configure_grd() {
  log "Configuring gnome-remote-desktop (port $RDP_PORT)…"
  # Note: FreeRDP prints "[ERROR] x509_utils_from_pem: BIO_new failed for
  # certificate" during these calls — that line is benign noise from FreeRDP's
  # auth path probing; the dconf settings are still written.
  grdctl --headless rdp set-tls-cert "$TLS_DIR/rdp.crt"
  grdctl --headless rdp set-tls-key  "$TLS_DIR/rdp.key"
  if [ "${REUSE_CREDS:-0}" = "0" ]; then
    # Pass both args — running interactively segfaults in grd 50.x without TPM.
    grdctl --headless rdp set-credentials "$RDP_USERNAME" "$RDP_PASSWORD"
  fi
  grdctl --headless rdp set-port "$RDP_PORT"
  grdctl --headless rdp disable-port-negotiation
  grdctl --headless rdp enable
}

install_user_environment() {
  # systemd --user reads ~/.config/environment.d/*.conf at start and exports
  # those vars to every user service + dbus-activated app. We use this for
  # two things gnome-session would normally export but doesn't here (we run
  # gnome-shell standalone with --mode=user):
  #   10-wsl-gpu.conf       — GALLIUM_DRIVER=d3d12 so client apps render on
  #                           the GPU instead of falling through to llvmpipe.
  #   20-gnome-session.conf — XDG_CURRENT_DESKTOP/SESSION_TYPE so apps that
  #                           gate on the desktop name (gnome-control-center,
  #                           gnome-software, portals) actually launch.
  # The gnome-shell unit also sets GALLIUM_DRIVER + the XDG vars in its own
  # Environment= block, so the compositor itself doesn't depend on these
  # files being read.
  local target_dir="$HOME/.config/environment.d"
  log "Installing user environment overrides to $target_dir…"
  mkdir -p "$target_dir"
  for src in "$PROJECT_ROOT"/environment.d/*.conf; do
    install -m 644 "$src" "$target_dir/$(basename "$src")"
  done
  # Push into the already-running user manager so the change takes effect
  # without a logout. New dbus activations and `systemctl --user start`s pick
  # this up immediately; apps already running keep their old env until
  # restarted.
  systemctl --user set-environment \
    GALLIUM_DRIVER=d3d12 \
    XDG_CURRENT_DESKTOP=GNOME \
    XDG_SESSION_TYPE=wayland
}

install_systemd_units() {
  log "Writing systemd user units to $SYSTEMD_USER_DIR…"
  mkdir -p "$SYSTEMD_USER_DIR" \
           "$SYSTEMD_USER_DIR/gnome-remote-desktop-headless.service.d"

  install -m 644 "$PROJECT_ROOT/units/gnome-shell-headless.service" \
                 "$SYSTEMD_USER_DIR/gnome-shell-headless.service"

  install -m 644 "$PROJECT_ROOT/units/gnome-remote-desktop-headless.override.conf" \
                 "$SYSTEMD_USER_DIR/gnome-remote-desktop-headless.service.d/override.conf"

  install -m 644 "$PROJECT_ROOT/units/wslg-pulse-detach.service" \
                 "$SYSTEMD_USER_DIR/wslg-pulse-detach.service"

  log "Reloading systemd user manager and starting services…"
  systemctl --user daemon-reload
  systemctl --user reset-failed \
    gnome-shell-headless.service \
    gnome-remote-desktop-headless.service \
    pipewire-pulse.socket 2>/dev/null || true

  # WSLg pre-symlinks /run/user/$UID/pulse → /mnt/wslg/runtime-dir/pulse,
  # which is mode 0700 owned by UID 1000. On a renumbered UID (see
  # lib/cgroup_collision.sh) we can't bind that socket. Enable + run our
  # detach unit BEFORE pipewire-pulse.socket so the latter can bind. The
  # unit is a no-op when the WSLg target is writable (i.e. the dylan=1000
  # case on the first distro).
  systemctl --user enable --now wslg-pulse-detach.service

  # PipeWire + WirePlumber are required by gnome-remote-desktop for screen
  # capture. They auto-start on graphical login but NOT in a headless + linger
  # setup, so enable + start them explicitly. Without them the RDP handshake
  # completes and the session dies at video-stream init — Windows reports
  # error 0x904 "session ended". pipewire-pulse handles RDP audio.
  systemctl --user enable --now \
    pipewire.socket \
    pipewire-pulse.socket \
    wireplumber.service

  systemctl --user enable  gnome-shell-headless.service           >/dev/null
  systemctl --user enable  gnome-remote-desktop-headless.service  >/dev/null
  systemctl --user restart gnome-shell-headless.service
  systemctl --user restart gnome-remote-desktop-headless.service
}
