# lib/prompt.sh — upfront interactive prompts.
#
# Everything that asks the user something runs from prompt_all_settings()
# at the very start of install.sh, before any heavy work, so an installer
# run is quiet from there on out. Two halves:
#
#   1. RDP credentials — username (default $USER), password (asked twice
#      with a confirmation pass; empty/mismatched re-prompts). Skipped when
#      `-u`/`-p` was passed on the CLI, or when grdctl already has stored
#      credentials and no flag was passed (re-run case).
#
#   2. Component checklist — whiptail's --checklist with arrow-nav + space
#      to toggle + tab to OK + enter to confirm. Toggles INSTALL_DESKTOP,
#      INSTALL_FLATPAK, INSTALL_POP_SHELL, INSTALL_APPINDICATOR,
#      INSTALL_RENDERD. Pre-checked from the corresponding env vars (so
#      `-m` / `INSTALL_X=0` show up as already-unchecked).
#
# Whiptail (newt on Fedora, whiptail on Debian/Ubuntu) is auto-installed
# via _ensure_whiptail() if missing.

# Install whiptail on demand (not during install_packages — we need it
# before that step runs).
_ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  case "$DISTRO_FAMILY" in
    fedora-like)
      ui_spin "Install whiptail (selection UI)" sudo dnf install -y newt
      ;;
    debian-like)
      ui_spin "Install whiptail (selection UI)" \
        sudo apt-get install -y --no-install-recommends whiptail
      ;;
    *)
      die "_ensure_whiptail: unsupported family $DISTRO_FAMILY"
      ;;
  esac
}

# Detect re-run with stored grdctl creds. Returns 0 if creds can be reused
# (and no -u/-p was passed), 1 otherwise.
_grdctl_has_stored_creds() {
  [ -n "$RDP_USERNAME" ] || [ -n "$RDP_PASSWORD" ] && return 1
  command -v grdctl >/dev/null 2>&1 || return 1
  grdctl --headless status 2>/dev/null \
    | grep -qE '^[[:space:]]*Username:[[:space:]]*\(hidden\)'
}

_prompt_credentials() {
  if _grdctl_has_stored_creds; then
    REUSE_CREDS=1
    ui_skip "Reusing stored RDP credentials (pass -u/-p to change)"
    return 0
  fi
  REUSE_CREDS=0

  if [ -z "$RDP_USERNAME" ]; then
    RDP_USERNAME=$(whiptail --title "RDP credentials" \
      --inputbox "RDP login username:" 10 60 "$USER" \
      3>&1 1>&2 2>&3) || die "Cancelled at RDP username prompt."
    RDP_USERNAME="${RDP_USERNAME:-$USER}"
  fi

  if [ -z "$RDP_PASSWORD" ]; then
    local pw1 pw2
    while :; do
      pw1=$(whiptail --title "RDP credentials" \
        --passwordbox "RDP password for $RDP_USERNAME:" 10 60 \
        3>&1 1>&2 2>&3) || die "Cancelled at RDP password prompt."
      if [ -z "$pw1" ]; then
        whiptail --title "Password" \
          --msgbox "Password cannot be empty. Try again." 8 50
        continue
      fi
      pw2=$(whiptail --title "RDP credentials" \
        --passwordbox "Confirm password (re-enter):" 10 60 \
        3>&1 1>&2 2>&3) || die "Cancelled at password confirmation."
      if [ "$pw1" = "$pw2" ]; then break; fi
      whiptail --title "Password" \
        --msgbox "Passwords don't match — try again." 8 50
    done
    RDP_PASSWORD="$pw1"
  fi
}

_prompt_components() {
  # Pre-check defaults: anything currently set to 0 (e.g. via -m or env)
  # starts unchecked; everything else starts checked. Custom kernel
  # defaults to OFF since most users won't want it.
  local desktop_state=ON      flatpak_state=ON       pop_state=ON
  local indicator_state=ON    renderd_state=OFF
  [ "${INSTALL_DESKTOP:-1}"      = "0" ] && desktop_state=OFF
  [ "${INSTALL_FLATPAK:-1}"      = "0" ] && flatpak_state=OFF
  [ "${INSTALL_POP_SHELL:-1}"    = "0" ] && pop_state=OFF
  [ "${INSTALL_APPINDICATOR:-1}" = "0" ] && indicator_state=OFF
  case "${INSTALL_RENDERD:-}" in
    1|yes|true)        renderd_state=ON ;;
    0|no|false|skip)   renderd_state=OFF ;;
  esac

  local choices
  choices=$(whiptail --title "Optional components" \
    --checklist \
    "Pick components to install. Arrows to navigate, Space to toggle, Tab to switch to OK, Enter to confirm." \
    20 78 6 --separate-output \
      "desktop"      "GNOME desktop apps (Files, terminal, etc.)"   "$desktop_state" \
      "flatpak"      "Flatpak apps (Firefox, ONLYOFFICE)"           "$flatpak_state" \
      "pop_shell"    "Pop Shell tiling extension"                   "$pop_state" \
      "appindicator" "AppIndicator system-tray extension"           "$indicator_state" \
      "renderd"      "Custom kernel for /dev/dri/renderD128 (~10m)" "$renderd_state" \
    3>&1 1>&2 2>&3) || die "Cancelled at component selection."

  # Default everything to OFF, then turn on whatever was checked.
  INSTALL_DESKTOP=0
  INSTALL_FLATPAK=0
  INSTALL_POP_SHELL=0
  INSTALL_APPINDICATOR=0
  INSTALL_RENDERD=0
  local c
  for c in $choices; do
    case "$c" in
      desktop)      INSTALL_DESKTOP=1 ;;
      flatpak)      INSTALL_FLATPAK=1 ;;
      pop_shell)    INSTALL_POP_SHELL=1 ;;
      appindicator) INSTALL_APPINDICATOR=1 ;;
      renderd)      INSTALL_RENDERD=1 ;;
    esac
  done
  export INSTALL_DESKTOP INSTALL_FLATPAK INSTALL_POP_SHELL \
         INSTALL_APPINDICATOR INSTALL_RENDERD
}

# Public entry point — call from install.sh before any heavy work.
prompt_all_settings() {
  ui_phase "Setup"
  _ensure_whiptail
  _prompt_credentials
  _prompt_components

  export RDP_USERNAME RDP_PASSWORD REUSE_CREDS

  ui_ok "Setup captured"
  ui_detail "username=${RDP_USERNAME:-(reuse)}, port=${RDP_PORT}"
  local enabled=()
  [ "$INSTALL_DESKTOP"      = 1 ] && enabled+=("desktop")
  [ "$INSTALL_FLATPAK"      = 1 ] && enabled+=("flatpak")
  [ "$INSTALL_POP_SHELL"    = 1 ] && enabled+=("pop_shell")
  [ "$INSTALL_APPINDICATOR" = 1 ] && enabled+=("appindicator")
  [ "$INSTALL_RENDERD"      = 1 ] && enabled+=("renderd")
  ui_detail "components: ${enabled[*]:-(none)}"
}
