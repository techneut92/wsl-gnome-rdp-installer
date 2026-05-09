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
    GDK_BACKEND=wayland \
    XDG_CURRENT_DESKTOP=GNOME \
    XDG_SESSION_TYPE=wayland
}

enable_appindicator_extension() {
  # Add the AppIndicator/KStatusNotifierItem extension to the user's
  # `enabled-extensions` list. Without it gnome-shell exposes no system
  # tray (no StatusNotifierWatcher on the session bus); apps whose UI is
  # tray-icon-driven — jetbrains-toolbox is the headline example — refuse
  # to keep their main loop alive and exit silently after a feed refresh
  # ("Application shutdown as nothing keeps us alive" in toolbox.log).
  # The extension is installed system-wide by gnome-shell-extension-appindicator
  # in install_packages. We just need to enable it.
  #
  # We write directly via gsettings rather than `gnome-extensions enable`
  # because the latter requires gnome-shell to be running and to have
  # already scanned the extension dir; gsettings/dconf is unaffected by
  # shell state and the shell picks up the value on next start.
  local uuid='appindicatorsupport@rgcjonas.gmail.com'
  local current
  current="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '@as []')"
  case "$current" in
    *"$uuid"*)
      log "AppIndicator extension already enabled."
      return 0
      ;;
  esac
  if [ "$current" = "@as []" ] || [ "$current" = "[]" ]; then
    gsettings set org.gnome.shell enabled-extensions "['$uuid']"
  else
    # current looks like `['ext1@…', 'ext2@…']` — splice the new UUID in
    # before the closing bracket so we don't clobber any other enabled ones
    # (Pop Shell, etc.).
    gsettings set org.gnome.shell enabled-extensions "${current%]}, '$uuid']"
  fi
  log "Enabled AppIndicator extension (takes effect on next gnome-shell start)."
}

configure_wallpaper() {
  # Fedora 44 ships GNOME's default wallpapers as JPEG-XL (.jxl) but doesn't
  # package a gdk-pixbuf JXL loader (gdk-pixbuf2-modules-extra only contains
  # the XPM loader; libjxl is present but no pixbuf bridge). Mutter then
  # can't decode the default wallpaper and shows a fallback dotted-cross
  # pattern through every workspace — looks like a "big dotted grid" over
  # everything in the RDP session. Override picture-uri{,-dark} to the
  # vnc-{l,d}.png variants which are also in /usr/share/backgrounds/gnome
  # and which gdk-pixbuf decodes via the built-in PNG loader. Idempotent.
  local light='file:///usr/share/backgrounds/gnome/vnc-l.png'
  local dark='file:///usr/share/backgrounds/gnome/vnc-d.png'
  if [ ! -f "${light#file://}" ]; then
    log "vnc-l.png wallpaper not present; skipping wallpaper override."
    return 0
  fi
  log "Setting wallpaper to vnc-{l,d}.png (gnome-backgrounds JXL has no Fedora pixbuf loader)…"
  gsettings set org.gnome.desktop.background picture-uri      "$light"
  gsettings set org.gnome.desktop.background picture-uri-dark "$dark"
}

install_x11_unix_fix() {
  # WSL's /init recreates /tmp/.X11-unix as a symlink to /mnt/wslg/.X11-unix
  # on every boot. Mutter's Xwayland refuses to start when that path is a
  # symlink ("Directory \"/tmp/.X11-unix\" is missing the sticky bit"); on
  # such a session gnome-shell-headless can't run --no-x11 was dropped, so
  # we ship a system-level oneshot that replaces the symlink with a real
  # mode-1777 directory and X0-symlinks WSLg's socket back in (so DISPLAY=:0
  # still resolves to WSLg apps that go through Windows). Mutter then
  # spawns its own Xwayland under :1 inside the RDP session.
  log "Installing /etc/systemd/system/wslg-x11-unix-fix.service (system unit)…"
  sudo install -m 644 "$PROJECT_ROOT/units/wslg-x11-unix-fix.service" \
                       /etc/systemd/system/wslg-x11-unix-fix.service
  sudo systemctl daemon-reload
  sudo systemctl enable wslg-x11-unix-fix.service >/dev/null
  # Apply right now if the symlink is still in place from this boot (the
  # unit's ConditionPathIsSymbolicLink= guard makes it a no-op after the
  # first run, so re-running the installer is safe).
  if [ -L /tmp/.X11-unix ]; then
    sudo systemctl start wslg-x11-unix-fix.service
  fi
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
  # The upstream gnome-remote-desktop-headless.service has
  # `WantedBy=gnome-session.target` in its [Install] section, so a plain
  # `systemctl --user enable` only links it into gnome-session.target.wants/.
  # We don't run gnome-session in this headless stack (gnome-shell is launched
  # directly with --mode=user), so that target never activates and grd never
  # autostarts on boot — RDP only comes up because we restart it manually
  # below. Use add-wants to additionally link it into default.target.wants/
  # so it comes up alongside gnome-shell-headless.
  systemctl --user enable     gnome-remote-desktop-headless.service  >/dev/null
  systemctl --user add-wants  default.target gnome-remote-desktop-headless.service >/dev/null
  systemctl --user restart gnome-shell-headless.service
  systemctl --user restart gnome-remote-desktop-headless.service
}
