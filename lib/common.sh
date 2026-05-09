# lib/common.sh — distro detection + log compatibility shims.
#
# UI helpers (ui_step, ui_ok, ui_warn, ui_err, ui_skip, ui_detail,
# ui_spin, ui_phase, ui_subhead) live in lib/ui.sh, sourced before
# this file from install.sh.
#
# `log`/`warn`/`die` are kept as backwards-compat aliases for any
# call site we haven't migrated yet — they map onto the ui_* helpers
# so the visual is consistent. Prefer the ui_* helpers in new code.
#
# Sets the following globals (via detect_distro):
#   DISTRO_ID        e.g. fedora, ubuntu, debian
#   DISTRO_VERSION   e.g. 44, 24.04, 13
#   DISTRO_FAMILY    fedora-like | debian-like

log()  { ui_step "$*"; }
warn() { ui_warn "$*"; }
die()  { ui_err  "$*"; exit 1; }

detect_distro() {
  [ -f /etc/os-release ] || die "/etc/os-release missing — can't detect distro"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_VERSION="${VERSION_ID:-unknown}"

  case "$DISTRO_ID" in
    fedora|rhel|centos|rocky|almalinux)
      DISTRO_FAMILY="fedora-like"
      ;;
    ubuntu|debian|linuxmint|pop|elementary)
      DISTRO_FAMILY="debian-like"
      ;;
    *)
      # Fall back to ID_LIKE if ID itself is unknown
      case "${ID_LIKE:-}" in
        *fedora*|*rhel*) DISTRO_FAMILY="fedora-like" ;;
        *debian*)        DISTRO_FAMILY="debian-like" ;;
        *)               die "Unsupported distro: $DISTRO_ID (only fedora-like and debian-like are supported)" ;;
      esac
      ;;
  esac

  export DISTRO_ID DISTRO_VERSION DISTRO_FAMILY
}
