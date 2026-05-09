# lib/common.sh — log helpers + distro detection.
#
# Sets the following globals:
#   DISTRO_ID        e.g. fedora, ubuntu, debian
#   DISTRO_VERSION   e.g. 44, 24.04, 13
#   DISTRO_FAMILY    fedora-like | debian-like

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

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
