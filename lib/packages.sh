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
      # gnome-keyring is required by Fedora's xdg-desktop-portal config:
      # /usr/share/xdg-desktop-portal/portals.conf declares
      # `org.freedesktop.impl.portal.Secret=gnome-keyring;`. Without
      # gnome-keyring installed (and gnome-keyring-daemon running),
      # the portal frontend can crashloop while waiting for the Secret
      # impl to become claimable on dbus, which knock-on starves
      # Firefox/Nautilus/anything portal-aware. Reproduced 2026-05-10.
      ui_spin "Install GNOME + RDP packages (dnf)" \
        sudo dnf install -y \
          gnome-remote-desktop \
          gnome-shell \
          gnome-shell-extension-appindicator \
          gnome-keyring \
          mutter \
          openssl \
          xdg-user-dirs \
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
          gnome-keyring \
          mutter \
          openssl \
          xdg-user-dirs \
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

  # Mask rtkit-daemon IMMEDIATELY after package install — before anything
  # (pipewire-pulse.socket activation, gnome-shell start, portal startup)
  # can dbus-trigger rtkit's spawn. On the WSL2 kernel rtkit's startup
  # hits `pthread_create failed: Resource temporarily unavailable`, leaves
  # dbus name-resolution in a broken state, and downstream consumers
  # (xdg-desktop-portal queries MaxRealtimePriority) hang for 25s × 3
  # = 75s+ — past portal's 45s TimeoutStartSec, so portal crashloops
  # forever afterward. Masking BEFORE rtkit is ever activated means
  # dbus reports NameHasNoOwner instantly and portal proceeds in ~1s.
  # Diagnosed 2026-05-10: previous mask-during-install_systemd_units
  # was too late (pipewire enable already triggered rtkit by then).
  ui_spin "Mask rtkit-daemon.service (no-op + slow on WSL kernel)" \
    sudo systemctl mask rtkit-daemon.service

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
  # All flatpak base wiring (flathub --system + --user remotes,
  # global --nofilesystem=/tmp override, global XCURSOR_SIZE=24 pin)
  # is owned by wsl-qol's setup_flatpak_remotes and runs earlier
  # in the pipeline via bootstrap_wsl_qol. By the time we get here
  # the remotes are in place and the wsl-flatpak-wslg-sync.path unit
  # is watching the exports dir — the install below will trip it.
  ui_spin "Install Firefox + ONLYOFFICE flatpaks" \
    flatpak install --user --noninteractive --assumeyes \
      flathub \
      org.mozilla.firefox \
      org.onlyoffice.desktopeditors
}

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
