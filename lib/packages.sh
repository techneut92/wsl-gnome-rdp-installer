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
      # mesa-vulkan-drivers ships dzn (Mesa's Vulkan-on-D3D12 ICD). On
      # Ubuntu 26.04 gnome-core doesn't pull it transitively the way
      # Fedora 44's gnome-shell metapackage does, so without an explicit
      # add `vulkaninfo --summary` reports "no device found" on a fresh
      # install. Mutter / gnome-remote-desktop don't need Vulkan, but
      # GTK 4.20+ defaults to its Vulkan renderer — on NVIDIA hosts dzn
      # is the "known good" path (diagnose.sh:89); on Intel Arc Xe the
      # GSK_RENDERER=ngl override already in lib/configure.sh routes GTK
      # around it. Pulling the package keeps Ubuntu's behaviour matched
      # to Fedora's.
      ui_spin "Install GNOME + RDP packages (apt)" \
        sudo apt-get install -y --no-install-recommends \
          gnome-remote-desktop \
          gnome-shell \
          gnome-shell-extension-appindicator \
          gnome-keyring \
          mutter \
          mesa-vulkan-drivers \
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

  # Same class of fix on debian-like only — Ubuntu ships dbus activation
  # files for hardware-bound system services that never come up on WSL:
  #
  #   bluetooth.service     → org.bluez (bluetoothd hardware-discovery loop)
  #   ModemManager.service  → org.freedesktop.ModemManager1 (no modems)
  #   fwupd.service         → org.freedesktop.fwupd        (no firmware to flash)
  #
  # On Fedora these all fail-fast on the WSL kernel (unit exits non-zero
  # before dbus times out), but Ubuntu's variants linger and dbus then
  # waits its full per-call timeout — 25000ms each for bluez +
  # ModemManager, 25000ms for fwupd. gnome-control-center probes all
  # three on launch (cc-bluetooth-panel, cc-wwan-panel, the About panel's
  # firmware section), so Settings appears to hang 30-60s before painting
  # on Ubuntu. Masking returns "Unit is masked" to dbus immediately and
  # callers proceed instantly.
  if [ "$DISTRO_FAMILY" = "debian-like" ]; then
    ui_spin "Mask bluetooth.service (no BT on WSL kernel; 25s dbus timeout)" \
      sudo systemctl mask bluetooth.service
    ui_spin "Mask ModemManager.service (no modems on WSL kernel; 25s dbus timeout)" \
      sudo systemctl mask ModemManager.service
    ui_spin "Mask fwupd.service (no firmware to flash on WSL kernel)" \
      sudo systemctl mask fwupd.service
  fi

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
