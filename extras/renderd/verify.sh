#!/usr/bin/env bash
# extras/renderd/verify.sh — post-`wsl --shutdown` verification for the
# opt-in custom kernel installed by lib/renderd_kernel.sh.
#
# Run this after `wsl --shutdown` + re-launch. It checks four things and
# prints PASS/FAIL for each, with hints when something didn't take.

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

printf '\n  %sCustom kernel verification%s\n\n' "$C_YELLOW" "$C_RESET"

# 1. VGEM is the backing driver for renderD128. We use the world-readable
# sysfs symlink (target contains "/vgem/") rather than dmesg, which on
# Fedora 44 and most modern distros requires CAP_SYSLOG.
if [ -e /sys/class/drm/renderD128 ] \
   && [[ $(readlink /sys/class/drm/renderD128 2>/dev/null) == */vgem/* ]]; then
  check "VGEM is the backing driver for renderD128" ok
else
  check "VGEM is the backing driver for renderD128" fail \
        "Either WSL didn't pick up the new kernel (forgot \`wsl --shutdown\`?), the build is missing CONFIG_DRM_VGEM, or another driver took the slot. Check \`readlink /sys/class/drm/renderD128\` — should contain '/vgem/'."
fi

# 2. Render node device file.
if [ -e /dev/dri/renderD128 ]; then
  check "/dev/dri/renderD128 exists" ok
else
  check "/dev/dri/renderD128 exists" fail \
        "Render node missing. Try \`ls /dev/dri/\` — if only card0 is there, VGEM is in the kernel but didn't auto-create the render node; try \`sudo modprobe vgem\` and re-check."
fi

# 3. .wslconfig points at our staged kernel.
if command -v wslpath >/dev/null && command -v cmd.exe >/dev/null; then
  win_home=$(cd / && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')
  if [ -n "$win_home" ]; then
    wslconfig=$(wslpath -u "$win_home")/.wslconfig
    expected=$(wslpath -u "$win_home")/.wsl-kernel/bzImage
    if [ -f "$wslconfig" ] && grep -qi 'kernel=.*\\.wsl-kernel\\\\bzImage' "$wslconfig"; then
      check ".wslconfig sets kernel= to .wsl-kernel\\bzImage" ok
    else
      check ".wslconfig sets kernel=" fail \
            "Expected $(wslpath -w "$expected" 2>/dev/null) in $(wslpath -w "$wslconfig" 2>/dev/null). Re-run install.sh."
    fi
  else
    check ".wslconfig sets kernel=" fail "couldn't resolve %USERPROFILE%"
  fi
else
  check ".wslconfig sets kernel=" fail "wslpath/cmd.exe missing — not WSL?"
fi

# 4. User in video and render groups.
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
        "Missing: ${missing[*]}. The installer ran usermod, but group changes only take effect on a fresh login. Try \`exec su - $USER\` or another \`wsl --shutdown\`."
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
