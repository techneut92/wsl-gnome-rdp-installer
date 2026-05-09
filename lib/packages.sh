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

  ui_spin "Install Firefox + ONLYOFFICE flatpaks" \
    flatpak install --user --noninteractive --assumeyes \
      flathub \
      org.mozilla.firefox \
      org.onlyoffice.desktopeditors

  expose_user_flatpaks_to_wslg
}

# WSLg's Start-Menu publisher (runs at distro startup, generates Windows
# .lnk shortcuts under "Apps → <distro>") scans only the two canonical
# XDG paths: /usr/share/applications and ~/.local/share/applications.
# `flatpak install --user` writes its .desktop files to a third path
# (~/.local/share/flatpak/exports/share/applications/), which is in
# XDG_DATA_DIRS for Linux but NOT in WSLg's hardcoded scan list — so
# user-installed flatpaks never appear in the Windows Start Menu.
#
# Symlink the per-app .desktop files (and only those) into
# ~/.local/share/applications so WSLg picks them up. Symlinks (not
# copies) keep flatpak the source of truth — Exec lines, version-bumped
# fields, and so on track upstream automatically.
#
# WSLg only republishes at distro startup, so existing WSL sessions
# need a `wsl -t <distro>` (or `wsl --shutdown`) to refresh the Start
# Menu after this runs.
expose_user_flatpaks_to_wslg() {
  local src="$HOME/.local/share/flatpak/exports/share/applications"
  local dst="$HOME/.local/share/applications"
  [ -d "$src" ] || return 0
  ui_step "Expose flatpaks to Windows Start Menu (WSLg)"
  mkdir -p "$dst"
  local f base linked=0 already=0
  for f in "$src"/*.desktop; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    if [ -L "$dst/$base" ] && [ "$(readlink -f "$dst/$base")" = "$(readlink -f "$f")" ]; then
      already=$((already + 1))
      continue
    fi
    ln -sfn "$f" "$dst/$base"
    linked=$((linked + 1))
  done
  if [ "$linked" -gt 0 ]; then
    ui_ok "Linked $linked flatpak .desktop entries"
    ui_detail "$dst → $src"
    ui_detail "run 'wsl -t <distro>' from Windows to refresh Start Menu"
  else
    ui_skip "All $already flatpak .desktop entries already exposed"
  fi
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
