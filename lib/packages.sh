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
# .lnk shortcuts under "Apps → <distro>") scans only /usr/share/applications,
# and only reads regular files — symlinks are silently skipped. Microsoft's
# docs claim ~/.local/share/applications is also walked + symlinks are
# resolved; empirically (WSL 2.7.3.0, 2026-05-09) neither is true.
#
# `flatpak install --user` writes its .desktop files to
# ~/.local/share/flatpak/exports/share/applications/ — XDG-visible to
# Linux clients (gnome-shell finds them in the dash) but invisible to
# WSLg's publisher. Same goes for icons in
# ~/.local/share/flatpak/exports/share/icons/.
#
# COPY the per-app .desktop files into /usr/share/applications and
# mirror the per-app icon tree into /usr/share/icons/hicolor/.../apps/
# (regular files, not symlinks). This means flatpak version-bumps that
# rewrite the .desktop won't auto-flow through — but that's the same
# tradeoff every other system-managed file in this installer makes,
# and an install.sh re-run rewrites it cleanly.
#
# WSLg only republishes at distro startup; surfaces in the verify hint
# via FLATPAKS_NEWLY_LINKED=1 so the user knows to `wsl -t <distro>`.
expose_user_flatpaks_to_wslg() {
  local src="$HOME/.local/share/flatpak/exports/share/applications"
  local dst="/usr/share/applications"
  [ -d "$src" ] || return 0
  ui_step "Expose flatpaks to Windows Start Menu (WSLg)"

  local f base copied=0 already=0
  for f in "$src"/*.desktop; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    # Regular file at dest with identical content → already in place.
    if [ -f "$dst/$base" ] && [ ! -L "$dst/$base" ] \
       && cmp -s "$f" "$dst/$base"; then
      already=$((already + 1))
      continue
    fi
    sudo rm -f "$dst/$base"
    sudo install -m 644 "$f" "$dst/$base"
    copied=$((copied + 1))
  done

  # Mirror per-app icons (hicolor tree) into /usr/share/icons. WSLg
  # embeds the icon into the .lnk shortcut by walking standard XDG
  # icon paths. Without this, Start Menu entries get a generic Linux
  # icon. Same regular-file rule applies — copies, not symlinks.
  # Scoped to org.mozilla.firefox* and org.onlyoffice.desktopeditors*
  # so we don't shadow other parts of the hicolor tree.
  local icon_src="$HOME/.local/share/flatpak/exports/share/icons"
  local icon_dst="/usr/share/icons"
  if [ -d "$icon_src" ]; then
    local icon
    while IFS= read -r icon; do
      local rel="${icon#"$icon_src/"}"
      local target="$icon_dst/$rel"
      if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$icon" "$target"; then
        continue
      fi
      sudo rm -f "$target"
      sudo install -d "$(dirname "$target")"
      sudo install -m 644 "$icon" "$target"
    done < <(find "$icon_src" -type l \
                  \( -name 'org.mozilla.firefox*' \
                  -o -name 'org.onlyoffice.desktopeditors*' \) 2>/dev/null)
  fi

  if [ "$copied" -gt 0 ]; then
    ui_ok "Copied $copied flatpak .desktop entries (+ icons)"
    ui_detail "$dst (copies of $src/*)"
    # Drives the "distro restart needed" hint in verify_and_print_summary.
    export FLATPAKS_NEWLY_LINKED=1
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
