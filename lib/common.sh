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

# Identify the WSLg primary host GPU by inspecting which Windows driver INF
# directory got mirrored into /usr/lib/wsl/drivers/. Reliable because WSLg
# only mirrors the driver package backing the adapter it exposes via dxgkrnl:
#   iigd_dch.inf_*  → Intel iGPU (UHD/Iris Xe/Arc Xe — incl. Meteor Lake)
#   nv_*.inf_*      → NVIDIA  (nv_dispi, nvlt, nvltwu, nv_oem*…)
#   u*amd*.inf_*    → AMD/Radeon (u0335006, u0341423, etc.)
# Echoes one of: intel | nvidia | amd | unknown.
host_gpu_vendor() {
  local d
  for d in /usr/lib/wsl/drivers/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      iigd_*|igdlh*|ki12*|ki13*) echo intel ; return 0 ;;
      nv_*|nvlt*|nvm*)            echo nvidia; return 0 ;;
      u*amd*|amdkmpfd*|u033*|u034*|u041*) echo amd; return 0 ;;
    esac
  done
  echo unknown
}

# Pick a Mesa Gallium driver for the compositor + user-session apps.
#
# WSL_RDP_GALLIUM_DRIVER overrides; otherwise auto-detect by host GPU.
#   d3d12     — Mesa → D3D12 → DXG → host driver. Hardware-accelerated.
#               Verified on NVIDIA. Produces a broken EGL/GBM surface on
#               Intel Arc Xe (Meteor Lake) — gnome-shell paints into a
#               context that never reaches the RDP capture path, so the
#               client sees a black screen with only the cursor visible.
#               Opening the D3D12 device on the shared iGPU adapter can
#               also briefly knock Windows DWM into recovery (host
#               wallpaper goes black).
#   llvmpipe  — software rasterizer. Slower, always correct.
#   auto      — Intel → llvmpipe ; NVIDIA/AMD/unknown → d3d12.
#
# Echoes the chosen driver string.
pick_gallium_driver() {
  local override="${WSL_RDP_GALLIUM_DRIVER:-auto}"
  case "$override" in
    d3d12|llvmpipe|softpipe|swrast) echo "$override"; return 0 ;;
    auto) ;;
    *)
      ui_warn "Unknown WSL_RDP_GALLIUM_DRIVER='$override' — falling back to auto"
      ;;
  esac
  case "$(host_gpu_vendor)" in
    intel) echo llvmpipe ;;
    *)     echo d3d12 ;;
  esac
}

# Pick a GSK renderer for GTK 4 apps.
#
# WSL_RDP_GSK_RENDERER overrides; otherwise auto-detect by host GPU.
#   ngl     — GSK's OpenGL renderer. Routes GTK 4 rendering through
#             Mesa's GL stack (d3d12 on NVIDIA/AMD, llvmpipe on Intel).
#   vulkan  — GSK's Vulkan renderer. On WSL2 this means Mesa's dzn
#             (Vulkan-on-DX12), which Mesa flags as 'not a conformant
#             Vulkan implementation, testing use only'. Works on NVIDIA;
#             crashes GTK 4 apps on Intel Arc Xe (Nautilus → SIGABRT
#             with VK_ERROR_DEVICE_LOST within seconds).
#   cairo   — software Cairo renderer. Slowest, always correct.
#   ""      — leave GSK alone; GTK picks its default (Vulkan on GTK 4.20+).
#
# Defaults: Intel → ngl, others → "" (GTK default). On Intel-broken
# hardware where GALLIUM_DRIVER=llvmpipe is already in effect, ngl just
# routes GTK 4 through software OpenGL — same place its other rendering
# already lives.
#
# Echoes the chosen renderer string (possibly empty).
pick_gsk_renderer() {
  local override="${WSL_RDP_GSK_RENDERER:-auto}"
  case "$override" in
    ngl|vulkan|cairo|gl) echo "$override"; return 0 ;;
    none|"")             echo ""; return 0 ;;
    auto) ;;
    *)
      ui_warn "Unknown WSL_RDP_GSK_RENDERER='$override' — falling back to auto"
      ;;
  esac
  case "$(host_gpu_vendor)" in
    intel) echo ngl ;;
    *)     echo "" ;;
  esac
}

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
