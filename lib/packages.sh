# lib/packages.sh — install distro-appropriate packages.

install_packages() {
  ui_step "Packages"
  case "$DISTRO_FAMILY" in
    fedora-like)
      # gnome-remote-desktop pulls freerdp-libs as a dep. We don't add the
      # `freerdp` binary package: openssl handles cert generation on every
      # tested distro, and gnome-remote-desktop's own daemon validates certs
      # via libfreerdp at runtime. git/make/nodejs/typescript are pulled
      # in for the Pop Shell build (lib/pop_shell.sh).
      # gnome-shell-extension-appindicator gives us a system-tray host
      # (StatusNotifierWatcher on the session bus). Without it apps that
      # only present a tray icon — jetbrains-toolbox is the headline case —
      # silently exit because no UI keeps the process alive.
      ui_spin "Install GNOME + RDP packages (dnf)" \
        sudo dnf install -y \
          gnome-remote-desktop \
          gnome-shell \
          gnome-shell-extension-appindicator \
          mutter \
          openssl \
          flatpak \
          git \
          make \
          nodejs \
          typescript
      ;;
    debian-like)
      export DEBIAN_FRONTEND=noninteractive
      ui_spin "Refresh apt index" sudo apt-get update -qq
      ui_spin "Install GNOME + RDP packages (apt)" \
        sudo apt-get install -y --no-install-recommends \
          gnome-remote-desktop \
          gnome-shell \
          gnome-shell-extension-appindicator \
          mutter \
          openssl \
          dbus-user-session \
          flatpak \
          git \
          make \
          nodejs \
          node-typescript
      ;;
    *)
      die "install_packages: unsupported family $DISTRO_FAMILY"
      ;;
  esac

  if [ "${INSTALL_DESKTOP:-1}" = "1" ]; then
    install_desktop_apps
  else
    ui_skip "Full GNOME desktop apps (deselected)"
  fi
  if [ "${INSTALL_FLATPAK:-1}" = "1" ]; then
    install_flatpak_apps
  else
    ui_skip "Flatpak desktop apps (deselected)"
  fi
}

# Set up flathub (per-user remote, no sudo) and install desktop flatpaks.
# We prefer flatpak Firefox over the distro package so the same install.sh
# produces the same browser experience on Fedora and Debian-likes (Debian
# ships ESR; Fedora's mozilla-built RPM lags upstream). ONLYOFFICE has no
# distro package on Fedora and the upstream RPM lags; the flatpak is the
# upstream-maintained build. Idempotent: re-runs are no-ops once the remote
# and apps are present.
install_flatpak_apps() {
  ui_step "Flatpak desktop apps"

  # Initialize the SYSTEM flatpak installation too — even though we
  # install our apps per-user. Without /var/lib/flatpak/repo on disk,
  # bare `flatpak run <appid>` (which is what every flatpak .desktop
  # file's Exec= line resolves to) fails with `error: While opening
  # repository /var/lib/flatpak/repo: opening repo: opendir(...) No
  # such file or directory` and the launch exits 1. This breaks
  # gnome-shell-launched flatpaks (the dash doesn't pass --user; the
  # .desktop file doesn't either). Adding a remote with --if-not-exists
  # initializes the repo as a side-effect — empty is fine, our apps
  # still resolve from the user installation.
  ui_spin "Add flathub remote (--system, init repo)" \
    sudo flatpak remote-add --system --if-not-exists \
      flathub https://flathub.org/repo/flathub.flatpakrepo

  ui_spin "Add flathub remote (--user)" \
    flatpak remote-add --user --if-not-exists \
      flathub https://flathub.org/repo/flathub.flatpakrepo

  # Global flatpak override: deny host /tmp to every user flatpak.
  # On WSLg, /tmp/.X11-unix is a symlink to /mnt/wslg/.X11-unix (Microsoft's
  # X server socket dir). Any flatpak whose manifest declares
  # `filesystems=/tmp` causes bwrap to bind-mount the host /tmp into the
  # sandbox and then attempt a tmpfs mount on /tmp/.X11-unix to stage the
  # X11 socket area. The symlink target /mnt/wslg/ isn't bound into the
  # sandbox, so bwrap fails with `Can't mount tmpfs on /newroot/tmp/.X11-unix:
  # No such file or directory` and the app exits before main(). Confirmed
  # affected: org.onlyoffice.desktopeditors. The trigger is the /tmp
  # filesystem permission, not the x11 socket — many seemingly-Wayland-only
  # apps still ship with `filesystems=/tmp` for IPC. Setting this globally
  # (no APP-ID) means any future flatpak inherits the deny and just works;
  # apps that genuinely need /tmp would already have been broken on WSLg.
  # `flatpak override` is idempotent — re-runs are no-ops.
  ui_spin "Override flatpak sandbox: --nofilesystem=/tmp" \
    flatpak override --user --nofilesystem=/tmp

  # Pin XCURSOR_SIZE for every flatpak (no app id = global override).
  # Wayland-native flatpaks (Firefox) ignore this — mutter renders the
  # cursor for them. Xwayland-via-flatpak ones (CEF apps like
  # ONLYOFFICE Desktop Editors, Electron-X11, Java AWT) read XCURSOR_SIZE
  # from env and end up with a ~4x cursor when mutter scales it for a
  # HiDPI RDP client. Pinning to 24 (GNOME's default cursor-size)
  # short-circuits that. Idempotent.
  ui_spin "Override flatpak XCURSOR_SIZE=24 (global)" \
    flatpak override --user --env=XCURSOR_SIZE=24

  ui_spin "Install Firefox + ONLYOFFICE flatpaks" \
    flatpak install --user --noninteractive --assumeyes \
      flathub \
      org.mozilla.firefox \
      org.onlyoffice.desktopeditors

  # The wsl-flatpak-wslg-sync.path unit (installed by
  # install_wslg_flatpak_sync earlier in the pipeline) is already
  # watching the flatpak exports dir; the install above tripped it
  # and the sync ran in the background. Nothing to do here.
}

# Earlier versions of this file shipped expose_user_flatpaks_to_wslg
# here. It was a one-shot copy of two specific apps' .desktop+icon files
# into /usr/share, run from the install pipeline. Replaced by
# install_wslg_flatpak_sync (lib/configure.sh) which installs a
# generalised root-side sync script + a per-user systemd path-unit
# watcher, so any flatpak install/uninstall/update auto-publishes to
# the Start Menu without re-running this installer.

# Install the standard GNOME desktop app suite (Files/Nautilus, terminal,
# text editor, calculator, system monitor, etc.). The minimal install_packages
# above only gives you gnome-shell + mutter, which is a working compositor but
# leaves the app grid empty. Idempotent on re-run.
install_desktop_apps() {
  ui_step "GNOME desktop apps"
  case "$DISTRO_FAMILY" in
    fedora-like)
      # `gnome-desktop` is the Fedora group ID for the GNOME Desktop Environment
      # (apps + settings panels). Distinct from the gnome-desktop3/4 shared libs.
      ui_spin "Install GNOME desktop group (dnf)" \
        sudo dnf group install -y gnome-desktop
      ;;
    debian-like)
      # gnome-core = Files, gnome-terminal, text editor, calculator, etc.
      # Avoiding the `gnome` metapackage which would pull in LibreOffice, games,
      # and other things that don't belong on a WSL session.
      export DEBIAN_FRONTEND=noninteractive
      ui_spin "Install gnome-core (apt)" \
        sudo apt-get install -y gnome-core
      ;;
  esac
}

enable_lingering() {
  ui_step "User lingering"
  if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    ui_skip "already enabled for $USER"
    return 0
  fi
  ui_spin "Enable lingering for $USER" \
    sudo loginctl enable-linger "$USER"
  ui_detail "services keep running after logout"
}
