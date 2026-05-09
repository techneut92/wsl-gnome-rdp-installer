# lib/configure.sh — grdctl settings + systemd user units.

configure_grd() {
  ui_step "Configure gnome-remote-desktop"
  ui_detail "port $RDP_PORT"
  # Note: FreeRDP prints "[ERROR] x509_utils_from_pem: BIO_new failed for
  # certificate" during these calls — that line is benign noise from FreeRDP's
  # auth path probing; the dconf settings are still written.
  ui_spin "Set TLS cert/key + port + enable RDP" bash -c '
    set -e
    grdctl --headless rdp set-tls-cert "'"$TLS_DIR"'/rdp.crt"
    grdctl --headless rdp set-tls-key  "'"$TLS_DIR"'/rdp.key"
    if [ "'"${REUSE_CREDS:-0}"'" = "0" ]; then
      grdctl --headless rdp set-credentials "'"$RDP_USERNAME"'" "'"$RDP_PASSWORD"'"
    fi
    grdctl --headless rdp set-port "'"$RDP_PORT"'"
    grdctl --headless rdp disable-port-negotiation
    grdctl --headless rdp enable
  '
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
  ui_step "User environment overrides"
  local target_dir="$HOME/.config/environment.d"
  mkdir -p "$target_dir"
  for src in "$PROJECT_ROOT"/environment.d/*.conf; do
    install -m 644 "$src" "$target_dir/$(basename "$src")"
  done
  ui_ok "Install environment.d/*.conf"
  ui_detail "$target_dir"
  # Push into the already-running user manager so the change takes effect
  # without a logout. New dbus activations and `systemctl --user start`s pick
  # this up immediately; apps already running keep their old env until
  # restarted.
  ui_spin "Push env into running user manager" \
    systemctl --user set-environment \
      GALLIUM_DRIVER=d3d12 \
      GDK_BACKEND=wayland \
      XDG_CURRENT_DESKTOP=GNOME \
      XDG_SESSION_TYPE=wayland
}

install_xdg_user_dirs() {
  # Standard ~/Downloads, ~/Documents, ~/Pictures, ~/Music, ~/Videos,
  # ~/Desktop, ~/Templates, ~/Public. On a normal GNOME box these are
  # created by `xdg-user-dirs-update` running from
  # /etc/xdg/autostart/xdg-user-dirs.desktop at gnome-session start.
  # We don't run gnome-session here (`gnome-shell --mode=user` directly),
  # so the autostart entry never fires and the dirs never appear — file
  # dialogs get a flat $HOME with .config/.cache/.local visible.
  #
  # `xdg-user-dirs-update`:
  #   - reads /etc/xdg/user-dirs.defaults for the list of dirs + locale
  #     translations (e.g. Bilder/Pictures depending on $LANG),
  #   - mkdir -p's each one,
  #   - writes ~/.config/user-dirs.dirs and ~/.config/user-dirs.locale.
  # Idempotent — re-running is a no-op once the dirs exist.
  ui_step "XDG user dirs"
  if ! command -v xdg-user-dirs-update >/dev/null 2>&1; then
    ui_skip "xdg-user-dirs-update not installed"
    return 0
  fi
  if [ -f "$HOME/.config/user-dirs.dirs" ] \
     && [ -d "$HOME/Downloads" ] \
     && [ -d "$HOME/Documents" ]; then
    ui_skip "user-dirs.dirs + standard folders already in place"
    return 0
  fi
  ui_spin "Run xdg-user-dirs-update" xdg-user-dirs-update
  ui_detail "Downloads, Documents, Pictures, Music, Videos, Desktop, Templates, Public"
}

enable_appindicator_extension() {
  ui_step "AppIndicator extension"
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
      ui_skip "already enabled"
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
  ui_ok "Enable AppIndicator"
  ui_detail "takes effect on next gnome-shell start"
}

install_x11_unix_fix() {
  ui_step "WSLg /tmp/.X11-unix fix"
  # WSL's /init recreates /tmp/.X11-unix as a symlink to /mnt/wslg/.X11-unix
  # on every boot. Mutter's Xwayland refuses to start when that path is a
  # symlink ("Directory \"/tmp/.X11-unix\" is missing the sticky bit"); on
  # such a session gnome-shell-headless can't run --no-x11 was dropped, so
  # we ship a system-level oneshot that replaces the symlink with a real
  # mode-1777 directory and X0-symlinks WSLg's socket back in (so DISPLAY=:0
  # still resolves to WSLg apps that go through Windows). Mutter then
  # spawns its own Xwayland under :1 inside the RDP session.
  ui_spin "Install + enable wslg-x11-unix-fix.service" bash -c '
    set -e
    sudo install -m 644 "'"$PROJECT_ROOT"'/units/wslg-x11-unix-fix.service" \
                         /etc/systemd/system/wslg-x11-unix-fix.service
    sudo systemctl daemon-reload
    sudo systemctl enable wslg-x11-unix-fix.service
  '
  # Apply right now if the symlink is still in place from this boot (the
  # unit's ConditionPathIsSymbolicLink= guard makes it a no-op after the
  # first run, so re-running the installer is safe).
  if [ -L /tmp/.X11-unix ]; then
    ui_spin "Run wslg-x11-unix-fix.service now" \
      sudo systemctl start wslg-x11-unix-fix.service
  else
    ui_skip "/tmp/.X11-unix already a real dir"
  fi
}

install_systemd_units() {
  ui_step "User systemd units"
  mkdir -p "$SYSTEMD_USER_DIR" \
           "$SYSTEMD_USER_DIR/gnome-remote-desktop-headless.service.d"

  install -m 644 "$PROJECT_ROOT/units/gnome-shell-headless.service" \
                 "$SYSTEMD_USER_DIR/gnome-shell-headless.service"

  install -m 644 "$PROJECT_ROOT/units/gnome-remote-desktop-headless.override.conf" \
                 "$SYSTEMD_USER_DIR/gnome-remote-desktop-headless.service.d/override.conf"

  install -m 644 "$PROJECT_ROOT/units/wslg-pulse-detach.service" \
                 "$SYSTEMD_USER_DIR/wslg-pulse-detach.service"
  ui_ok "Write unit files"
  ui_detail "$SYSTEMD_USER_DIR"

  ui_spin "Reload user manager + reset-failed" bash -c '
    systemctl --user daemon-reload
    systemctl --user reset-failed \
      gnome-shell-headless.service \
      gnome-remote-desktop-headless.service \
      pipewire-pulse.socket 2>/dev/null || true
  '

  # WSLg pre-symlinks /run/user/$UID/pulse → /mnt/wslg/runtime-dir/pulse,
  # which is mode 0700 owned by UID 1000. On a renumbered UID (see
  # lib/cgroup_collision.sh) we can't bind that socket. Enable + run our
  # detach unit BEFORE pipewire-pulse.socket so the latter can bind. The
  # unit is a no-op when the WSLg target is writable (i.e. the dylan=1000
  # case on the first distro).
  ui_spin "Enable wslg-pulse-detach.service" \
    systemctl --user enable --now wslg-pulse-detach.service

  # PipeWire + WirePlumber are required by gnome-remote-desktop for screen
  # capture. They auto-start on graphical login but NOT in a headless + linger
  # setup, so enable + start them explicitly. Without them the RDP handshake
  # completes and the session dies at video-stream init — Windows reports
  # error 0x904 "session ended". pipewire-pulse handles RDP audio.
  ui_spin "Enable pipewire + wireplumber" \
    systemctl --user enable --now \
      pipewire.socket \
      pipewire-pulse.socket \
      wireplumber.service

  # The upstream gnome-remote-desktop-headless.service has
  # `WantedBy=gnome-session.target` in its [Install] section, so a plain
  # `systemctl --user enable` only links it into gnome-session.target.wants/.
  # We don't run gnome-session in this headless stack (gnome-shell is launched
  # directly with --mode=user), so that target never activates and grd never
  # autostarts on boot — RDP only comes up because we restart it manually
  # below. Use add-wants to additionally link it into default.target.wants/
  # so it comes up alongside gnome-shell-headless.
  ui_spin "Enable + restart RDP services" bash -c '
    systemctl --user enable    gnome-shell-headless.service              >/dev/null
    systemctl --user enable    gnome-remote-desktop-headless.service     >/dev/null
    systemctl --user add-wants default.target gnome-remote-desktop-headless.service >/dev/null
    systemctl --user restart gnome-shell-headless.service
    systemctl --user restart gnome-remote-desktop-headless.service
  '
}
