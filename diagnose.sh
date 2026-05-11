#!/usr/bin/env bash
# diagnose.sh — read-only probe of the WSL2 / GNOME / RDP environment.
# Run before install.sh to see what the installer is going to detect, what
# the auto-detection will choose, and which paths are known-broken on the
# current hardware. Run after install.sh to triage rendering / crash
# problems without poking the running services.
#
# Touches nothing. Suggests but never installs.
#
# Usage:
#   ./diagnose.sh            full report
#   ./diagnose.sh -q         skip the live GL / Vulkan probes (faster)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
. "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=lib/common.sh
. "$PROJECT_ROOT/lib/common.sh"

QUICK=0
while getopts ":qh" opt; do
  case "$opt" in
    q) QUICK=1 ;;
    h) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) ;;
  esac
done

# ---------- System basics ----------------------------------------------
ui_phase "System"

# detect_distro sets DISTRO_ID, DISTRO_VERSION, DISTRO_FAMILY. Tolerate
# unsupported distros here (we're diagnosing, not installing).
if detect_distro 2>/dev/null; then
  ui_ok "Distro: $DISTRO_ID $DISTRO_VERSION ($DISTRO_FAMILY)"
else
  ui_warn "Distro: unsupported / unknown — installer would refuse"
  DISTRO_FAMILY=unknown
fi
ui_detail "kernel: $(uname -r)"
ui_detail "cpu:    $(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')"
ui_detail "user:   $USER (uid $(id -u))"

# systemd is a hard requirement for install.sh
if [ -d /run/systemd/system ]; then
  ui_ok "systemd: running as PID 1"
else
  ui_err "systemd: NOT running — install.sh will refuse"
  ui_detail "add [boot]\\nsystemd=true to /etc/wsl.conf, wsl --shutdown"
fi

# Lingering keeps user services alive after shell logout
if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
  ui_ok "User lingering: enabled"
else
  ui_skip "User lingering: disabled (install.sh will enable)"
fi

# ---------- WSL state --------------------------------------------------
ui_phase "WSL"

if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
  ui_ok "WSL kernel: $(cat /proc/sys/kernel/osrelease)"
else
  ui_warn "Not a WSL kernel — installer is WSL-targeted"
fi

ui_detail "WSL_DISTRO_NAME: ${WSL_DISTRO_NAME:-<unset>}"
ui_detail "WSLg socket:     $([ -S /mnt/wslg/runtime-dir/wayland-0 ] && echo present || echo missing)"

# Detect multi-distro cgroup collision — same UID owning user@.service in
# two distros causes the second to fail systemd. install.sh's
# precheck_cgroup_collision tests this; here we just report.
if [ -f "/sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.procs" ]; then
  procs=$(wc -l < "/sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.procs")
  ui_detail "user-$(id -u).slice has $procs procs"
fi

# ---------- Host GPU detection ----------------------------------------
ui_phase "Host GPU (via WSLg driver mirror)"

vendor=$(host_gpu_vendor)
case "$vendor" in
  intel)   ui_warn "Vendor: intel (Mesa d3d12 + dzn Vulkan known broken on Arc Xe)" ;;
  nvidia)  ui_ok   "Vendor: nvidia (Mesa d3d12 + dzn Vulkan known good)" ;;
  amd)     ui_ok   "Vendor: amd"   ;;
  unknown) ui_warn "Vendor: unknown — could not match /usr/lib/wsl/drivers/*.inf_amd64_*" ;;
esac
ui_detail "drivers mirrored: $(ls /usr/lib/wsl/drivers 2>/dev/null | grep -E '^(iigd|nv_|nvlt|u[0-9]+|amdkmpfd)' | head -3 | tr '\n' ' ')"

# /dev/dri layout — mutter scans this and picks a primary
ui_detail "/dev/dri:    $(ls /dev/dri 2>/dev/null | tr '\n' ' ' || echo missing)"
ui_detail "vgem:        $(lsmod | awk '$1=="vgem"{print "loaded"; exit}' || echo "not loaded")"
ui_detail "vkms:        $(lsmod | awk '$1=="vkms"{print "loaded"; exit}' || echo "not loaded")"

# ---------- Auto-detected install choices -----------------------------
ui_phase "Auto-detected install choices"

gallium=$(pick_gallium_driver)
gsk=$(pick_gsk_renderer)

ui_step "GALLIUM_DRIVER → $gallium"
case "$gallium" in
  d3d12)    ui_detail "Mesa→D3D12→DXG→host driver (hardware on NVIDIA; broken on Intel Arc Xe)" ;;
  llvmpipe) ui_detail "software rasterizer (slow, always correct)" ;;
esac
ui_detail "override: WSL_RDP_GALLIUM_DRIVER={d3d12,llvmpipe,auto}"

ui_step "GSK_RENDERER → ${gsk:-<unset; GTK default>}"
case "$gsk" in
  ngl)    ui_detail "force GTK 4 onto OpenGL — dodges Mesa dzn Vulkan (Intel crashes Nautilus)" ;;
  vulkan) ui_detail "GTK 4 default since 4.20 — Mesa dzn, fine on NVIDIA" ;;
  cairo)  ui_detail "pure software — slowest but always correct" ;;
  "")     ui_detail "leave GTK at its default (Vulkan via Mesa dzn on 4.20+)" ;;
esac
ui_detail "override: WSL_RDP_GSK_RENDERER={ngl,vulkan,cairo,none,auto}"

# ---------- Live GL / Vulkan probes -----------------------------------
if [ "$QUICK" = "1" ]; then
  ui_phase "Live probes (skipped — -q)"
else
  ui_phase "Live probes"

  if command -v eglinfo >/dev/null 2>&1; then
    ui_step "OpenGL: d3d12 path"
    out=$(GALLIUM_DRIVER=d3d12 timeout 5 eglinfo -p surfaceless 2>&1 | grep -E '^(EGL version|OpenGL (vendor|renderer|version))' | head -4)
    if [ -n "$out" ]; then
      echo "$out" | sed 's/^/    /'
    else
      ui_err "d3d12 EGL surfaceless probe failed (no GL context)"
    fi

    ui_step "OpenGL: llvmpipe path"
    out=$(LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe timeout 5 eglinfo -p surfaceless 2>&1 | grep -E '^(EGL version|OpenGL (vendor|renderer|version))' | head -4)
    if [ -n "$out" ]; then
      echo "$out" | sed 's/^/    /'
    else
      ui_err "llvmpipe EGL surfaceless probe failed"
    fi
  else
    case "$DISTRO_FAMILY" in
      fedora-like) hint="sudo dnf install mesa-demos" ;;
      debian-like) hint="sudo apt install mesa-utils" ;;
      *)           hint="(install mesa-demos / mesa-utils)" ;;
    esac
    ui_skip "eglinfo not installed — skipping OpenGL probe"
    ui_detail "$hint"
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    ui_step "Vulkan: dzn path"
    out=$(timeout 5 vulkaninfo --summary 2>&1)
    if echo "$out" | grep -q 'apiVersion'; then
      echo "$out" | grep -E '(apiVersion|deviceName|driverName|driverInfo)' | head -8 | sed 's/^/    /'
      if echo "$out" | grep -qi 'dzn'; then
        ui_warn "dzn is loaded — Mesa's own warning: 'not a conformant Vulkan implementation, testing use only'"
      fi
    else
      ui_err "vulkaninfo failed (no Vulkan device found)"
    fi
  else
    case "$DISTRO_FAMILY" in
      fedora-like) hint="sudo dnf install vulkan-tools" ;;
      debian-like) hint="sudo apt install vulkan-tools" ;;
      *)           hint="(install vulkan-tools)" ;;
    esac
    ui_skip "vulkaninfo not installed — skipping Vulkan probe"
    ui_detail "$hint"
  fi
fi

# ---------- Existing installer state ----------------------------------
ui_phase "Existing installer state"

ui_step "environment.d"
if [ -d "$HOME/.config/environment.d" ]; then
  for f in "$HOME/.config/environment.d"/*.conf; do
    [ -f "$f" ] || continue
    ui_detail "$(basename "$f")"
    grep -vE '^\s*(#|$)' "$f" | sed 's/^/        /'
  done
else
  ui_skip "no ~/.config/environment.d/"
fi

ui_step "gnome-shell-headless drop-in"
dropin="$HOME/.config/systemd/user/gnome-shell-headless.service.d/10-gpu.conf"
if [ -f "$dropin" ]; then
  ui_ok "$dropin"
  sed 's/^/    /' "$dropin"
else
  ui_skip "no drop-in (compositor will inherit static unit env only)"
fi

ui_step "Live user manager env"
systemctl --user show-environment 2>/dev/null \
  | grep -E '^(GALLIUM_DRIVER|GSK_RENDERER|WAYLAND_DISPLAY|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|GDK_BACKEND)=' \
  | sed 's/^/    /'

# ---------- Services + recent crashes ---------------------------------
ui_phase "Services"

for svc in gnome-shell-headless gnome-remote-desktop-headless; do
  state=$(systemctl --user is-active "$svc.service" 2>/dev/null || echo "not-found")
  case "$state" in
    active)        ui_ok   "$svc: $state" ;;
    inactive)      ui_skip "$svc: $state" ;;
    failed)        ui_err  "$svc: $state" ;;
    not-found)     ui_skip "$svc: not installed yet" ;;
    *)             ui_warn "$svc: $state" ;;
  esac
done

# Look for the known-broken signatures in the last hour
ui_step "Recent known-broken signatures (last 1h)"
sig=$(journalctl --user --no-pager --since '1 hour ago' 2>&1 \
       | grep -iE 'D3D12: Removing|VK_ERROR_DEVICE_LOST|VK_ERROR_OUT_OF_DEVICE_MEMORY|grd_egl_thread.*SIGSEGV|killed.*signal|code=killed' \
       | tail -5)
if [ -n "$sig" ]; then
  ui_warn "found:"
  echo "$sig" | sed 's/^/    /'
else
  ui_ok "none"
fi

# ---------- RDP port -------------------------------------------------
ui_phase "RDP port"

port="${RDP_PORT:-3390}"
if ss -tlnp 2>/dev/null | grep -q ":$port "; then
  who=$(ss -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {print $NF; exit}')
  ui_ok "tcp:$port listening"
  ui_detail "$who"
else
  ui_skip "tcp:$port not listening yet"
fi

# ---------- Recommendation ----------------------------------------------
ui_phase "Recommendation"

case "$vendor:$gallium" in
  intel:llvmpipe)
    ui_warn "Intel iGPU detected — install.sh will pick llvmpipe + GSK_RENDERER=ngl."
    ui_detail "Compositor runs on software, but GTK 4 apps stay alive (Nautilus etc.)."
    ui_detail "Try WSL_RDP_GALLIUM_DRIVER=d3d12 later if Mesa / Intel driver updates."
    ;;
  nvidia:d3d12|amd:d3d12)
    ui_ok "$vendor + d3d12 — install.sh will use the hardware-accelerated path."
    ;;
  unknown:*)
    ui_warn "Could not detect host GPU vendor — install.sh will default to d3d12."
    ui_detail "If RDP shows a black screen with a cursor: WSL_RDP_GALLIUM_DRIVER=llvmpipe ./install.sh"
    ;;
esac

if [ ! -d /run/systemd/system ]; then
  ui_err "FIX FIRST: enable systemd in /etc/wsl.conf, then wsl --shutdown."
fi

# vim: set ts=2 sw=2 et:
