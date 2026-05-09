#!/usr/bin/env bash
# extras/renderd/verify.sh — sanity check for the renderd modules
# installed by lib/renderd_kernel.sh.
#
# Modules-only architecture: we drop vgem.ko + vkms.ko under
# /lib/modules/$(uname -r)/extra/ and persist them via
# /etc/modules-load.d/wsl-renderd.conf. No `wsl --shutdown` required —
# `modprobe` loads them immediately during install. This script reports
# PASS/FAIL on each artifact so post-install issues are easy to triage.

set -uo pipefail

C_GREEN=$'\033[1;32m'
C_RED=$'\033[1;31m'
C_YELLOW=$'\033[1;33m'
C_RESET=$'\033[0m'

pass=0; fail=0
check() {
  local label=$1 result=$2 hint=${3:-}
  if [ "$result" = "ok" ]; then
    printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$label"
    [ -n "$hint" ] && printf '       %s\n' "$hint"
    fail=$((fail+1))
  fi
}

printf '\n  %srenderd modules verification%s\n\n' "$C_YELLOW" "$C_RESET"

KREL=$(uname -r)
MODDIR="/lib/modules/$KREL/extra"

# 1. .ko files installed for the running kernel.
if [ -f "$MODDIR/vgem.ko" ] && [ -f "$MODDIR/vkms.ko" ]; then
  check "vgem.ko + vkms.ko installed at $MODDIR" ok
else
  missing=()
  [ -f "$MODDIR/vgem.ko" ] || missing+=("vgem.ko")
  [ -f "$MODDIR/vkms.ko" ] || missing+=("vkms.ko")
  check "vgem.ko + vkms.ko installed for $KREL" fail \
        "Missing under $MODDIR: ${missing[*]}. Re-run wsl-rdp-gnome-renew (modules might not have been built for this kernel version)."
fi

# 2. modprobe persistence file.
if [ -f /etc/modules-load.d/wsl-renderd.conf ]; then
  check "/etc/modules-load.d/wsl-renderd.conf in place" ok
else
  check "/etc/modules-load.d/wsl-renderd.conf in place" fail \
        "Without it, modules don't load at boot. Re-run wsl-rdp-gnome-renew."
fi

# 3. VGEM is the backing driver for renderD128 (sysfs check — works
# regardless of whether vgem is built-in or a loaded module).
if [ -e /sys/class/drm/renderD128 ] \
   && [[ $(readlink /sys/class/drm/renderD128 2>/dev/null) == */vgem/* ]]; then
  check "VGEM is the backing driver for renderD128" ok
else
  check "VGEM is the backing driver for renderD128" fail \
        "Either modprobe failed (try \`sudo modprobe vgem\` and check \`sudo dmesg | tail\`), or another driver took the slot."
fi

# 4. /dev/dri/renderD128 exists.
if [ -e /dev/dri/renderD128 ]; then
  check "/dev/dri/renderD128 exists" ok
else
  check "/dev/dri/renderD128 exists" fail \
        "Render node missing. Try \`ls /dev/dri/\` — if only card0 is there, VGEM didn't create the render node; try \`sudo modprobe vgem\` and re-check."
fi

# 5. User in video and render groups.
groups_now=$(id -nG "$USER")
in_video=0; in_render=0
echo "$groups_now" | tr ' ' '\n' | grep -qx video  && in_video=1
echo "$groups_now" | tr ' ' '\n' | grep -qx render && in_render=1
if [ $in_video -eq 1 ] && [ $in_render -eq 1 ]; then
  check "$USER is in 'video' and 'render' groups" ok
else
  missing=()
  [ $in_video -eq 0 ]  && missing+=("video")
  [ $in_render -eq 0 ] && missing+=("render")
  check "$USER is in 'video' and 'render' groups" fail \
        "Missing: ${missing[*]}. The installer ran usermod, but group changes only take effect on a fresh login. Try \`exec su - $USER\` or \`wsl --shutdown\` + re-enter."
fi

printf '\n'
if [ $fail -eq 0 ]; then
  printf '  %sAll %d checks passed.%s /dev/dri/renderD128 is available to apps in this session.\n\n' \
         "$C_GREEN" "$pass" "$C_RESET"
  exit 0
else
  printf '  %s%d/%d checks failed.%s See hints above.\n\n' \
         "$C_RED" "$fail" "$((pass+fail))" "$C_RESET"
  exit 1
fi
