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
#   2. Component checklist — inline multi-select rendered via
#      ui_multiselect (lib/ui.sh). Arrow keys to navigate, space to
#      toggle, enter to confirm, q/esc to cancel. Toggles INSTALL_DESKTOP,
#      INSTALL_FIREFOX, INSTALL_ONLYOFFICE, INSTALL_POP_SHELL,
#      INSTALL_RENDERD. Pre-checked from the corresponding env vars.
#
#      AppIndicator is NOT in the menu — it's mandatory (always installed)
#      because the headline tray-icon use case (jetbrains-toolbox)
#      silently exits its main loop without it.

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
    RDP_USERNAME=$(ui_input "RDP login username" "$USER")
    [ -z "$RDP_USERNAME" ] && RDP_USERNAME="$USER"
  fi

  if [ -z "$RDP_PASSWORD" ]; then
    local pw1 pw2
    while :; do
      pw1=$(ui_password "RDP password for $RDP_USERNAME")
      if [ -z "$pw1" ]; then
        ui_warn "Password cannot be empty — try again"
        continue
      fi
      pw2=$(ui_password "Confirm password (re-enter)")
      if [ "$pw1" = "$pw2" ]; then break; fi
      ui_warn "Passwords don't match — try again"
    done
    RDP_PASSWORD="$pw1"
  fi
}

_prompt_components() {
  # Pre-check defaults: everything starts checked unless explicitly
  # overridden (-m flag or `INSTALL_X=0` env). Custom-kernel modules
  # default ON now too — they're cheap (5–10s prebuilt download from
  # github.com/techneut92/wsl-renderd-modules) and they fix dma-buf
  # screen capture / Wayland gating in PipeWire/OBS/Firefox/etc. Users
  # who don't want them just uncheck the box.
  local desktop_state=ON   firefox_state=ON   onlyoffice_state=ON
  local pop_state=ON       renderd_state=ON
  [ "${INSTALL_DESKTOP:-1}"    = "0" ] && desktop_state=OFF
  [ "${INSTALL_FIREFOX:-1}"    = "0" ] && firefox_state=OFF
  [ "${INSTALL_ONLYOFFICE:-1}" = "0" ] && onlyoffice_state=OFF
  [ "${INSTALL_POP_SHELL:-1}"  = "0" ] && pop_state=OFF
  case "${INSTALL_RENDERD:-}" in
    0|no|false|skip)  renderd_state=OFF ;;
  esac

  local choices
  if ! choices=$(ui_multiselect "Optional components" \
    "desktop|GNOME desktop apps (Files, terminal, etc.)|$desktop_state" \
    "firefox|Firefox (flatpak, flathub)|$firefox_state" \
    "onlyoffice|ONLYOFFICE (flatpak, flathub)|$onlyoffice_state" \
    "pop_shell|Pop Shell tiling extension|$pop_state" \
    "renderd|Custom kernel for /dev/dri/renderD128 (~10m build)|$renderd_state"); then
    die "Cancelled at component selection."
  fi

  # Default everything to OFF, then turn on whatever was checked.
  INSTALL_DESKTOP=0
  INSTALL_FIREFOX=0
  INSTALL_ONLYOFFICE=0
  INSTALL_POP_SHELL=0
  INSTALL_RENDERD=0
  local c
  for c in $choices; do
    case "$c" in
      desktop)    INSTALL_DESKTOP=1 ;;
      firefox)    INSTALL_FIREFOX=1 ;;
      onlyoffice) INSTALL_ONLYOFFICE=1 ;;
      pop_shell)  INSTALL_POP_SHELL=1 ;;
      renderd)    INSTALL_RENDERD=1 ;;
    esac
  done
  export INSTALL_DESKTOP INSTALL_FIREFOX INSTALL_ONLYOFFICE \
         INSTALL_POP_SHELL INSTALL_RENDERD
}

# Public entry point — call from install.sh before any heavy work.
prompt_all_settings() {
  ui_phase "Setup"
  _prompt_credentials
  _prompt_components
  export RDP_USERNAME RDP_PASSWORD REUSE_CREDS
}
