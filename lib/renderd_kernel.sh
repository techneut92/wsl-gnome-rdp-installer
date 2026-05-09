# lib/renderd_kernel.sh — opt-in: build a custom WSL2 kernel exposing
# /dev/dri/renderD128 via CONFIG_DRM_VKMS=y + CONFIG_DRM_VGEM=y.
#
# Why: Microsoft's stock WSL kernel ships no DRM drivers at all, so
# /dev/dri/ is empty and any Linux app that gates a feature on a render
# node existing (PipeWire dma-buf screen capture, certain Wayland clients,
# EGL device-platform consumers, browser GPU sandboxing checks) silently
# disables itself. Adding VGEM/VKMS gives those apps a render node to
# discover. It does NOT add real GPU acceleration — VGEM is a virtual
# device, so apps still render via llvmpipe (CPU). It does NOT fix the
# chroma watermark in grd's RDP video stream — that needs a separate
# gnome-remote-desktop source patch (see notes/grd-vgem-journal-* in the
# author's local notes for the three-blocker analysis).
#
# Pipeline in install_renderd_kernel():
#   prompt_renderd_optin                                  ┐
#   renderd_already_active           → skip rebuild       │ skippable
#   renderd_preflight                → fail fast          │
#   renderd_install_build_deps                            │
#   renderd_clone_source                                  │ heavy
#   renderd_apply_config                                  │
#   renderd_build_kernel                                  ┘
#   renderd_stage_bzimage            → C:\Users\…\.wsl-kernel\bzImage
#   renderd_patch_wslconfig          → backup + edit %USERPROFILE%\.wslconfig
#   renderd_add_user_groups          → video, render
#   renderd_print_apply_instructions → user runs `wsl --shutdown`
#
# Non-interactive controls:
#   INSTALL_RENDERD=1    skip prompt, install
#   INSTALL_RENDERD=0    skip prompt, skip
#   INSTALL_RENDERD_FORCE=1
#                        rebuild even if VGEM is already active
#   RENDERD_SRCDIR=…     override clone location (default: ~/.cache/wsl-gnome-rdp/WSL2-Linux-Kernel)
#   RENDERD_TAG=…        override kernel tag (default: linux-msft-wsl-<uname -r prefix>)

# 0 = renderD128 already exposed by current kernel via VGEM, 1 = not.
renderd_already_active() {
  [ -e /dev/dri/renderD128 ] || return 1
  # Don't trust just the device node — could be from another driver. The
  # /sys/class/drm/renderD128 symlink target contains "/vgem/" iff VGEM is
  # the backing driver. Sysfs is world-readable, so this works without
  # root (`dmesg` is root-only on Fedora 44 and most modern distros).
  local link
  link=$(readlink /sys/class/drm/renderD128 2>/dev/null) || return 1
  [[ $link == */vgem/* ]]
}

# Print the explainer + ask. Returns 0 to install, 1 to skip.
prompt_renderd_optin() {
  case "${INSTALL_RENDERD:-}" in
    0|no|false|skip)
      ui_skip "Render-node kernel (INSTALL_RENDERD=$INSTALL_RENDERD)"
      return 1
      ;;
    1|yes|true)
      ui_ok "Render-node kernel: non-interactive install (INSTALL_RENDERD=$INSTALL_RENDERD)"
      return 0
      ;;
  esac

  cat <<'EOF'

──────────────────────────────────────────────────────────────────
  Optional: build a custom WSL kernel for /dev/dri/renderD128
──────────────────────────────────────────────────────────────────

  Some Linux apps gate features on a DRM render node — PipeWire
  screen capture (xdg-desktop-portal, OBS), certain Wayland
  clients, EGL device-platform consumers, browsers' GPU sandboxing
  checks. Microsoft's stock WSL kernel ships no DRM device at all,
  so those features silently disable themselves.

  This step builds a kernel with CONFIG_DRM_VGEM=y + CONFIG_DRM_VKMS=y
  to expose /dev/dri/renderD128 as a virtual render node.

  What this is NOT:
    • This does NOT enable real GPU acceleration. VGEM is virtual —
      apps still render via llvmpipe (CPU). It only unblocks code
      paths that disable themselves when no render node exists.
    • This does NOT fix the chroma watermark in the RDP video
      stream — that needs a separate gnome-remote-desktop patch.

  Cost:
    • 5–10 min build time (uses all CPU cores).
    • ~500 MB of kernel build dependencies installed.
    • Requires `wsl --shutdown` from Windows to apply.
    • Reversible: we back up .wslconfig before modifying it.

  Skip with INSTALL_RENDERD=0 to silence this prompt next time.

EOF
  local reply
  read -rp "  Build & install custom kernel now? [y/N]: " reply
  echo
  case "${reply,,}" in
    y|yes) return 0 ;;
    *)
      ui_skip "Render-node kernel (re-run with INSTALL_RENDERD=1 to install non-interactively)"
      return 1
      ;;
  esac
}

# Pre-build sanity. Fails fast before we burn 5–10 min compiling.
renderd_preflight() {
  command -v cmd.exe >/dev/null \
    || die "cmd.exe not on PATH — can't resolve %USERPROFILE%. Are you running under WSL2?"
  command -v wslpath >/dev/null \
    || die "wslpath not available — required to translate %USERPROFILE% to /mnt/c/…"
  command -v git >/dev/null \
    || die "git missing — should have been pulled in by install_packages"
  # Need ≥ 3 GB free for source (~1.5 GB) + build artifacts (~1 GB) + slack.
  local free_gb
  free_gb=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4+0}')
  [ -n "$free_gb" ] && [ "$free_gb" -ge 3 ] \
    || die "Need ≥ 3 GB free in \$HOME for kernel build (have ${free_gb:-?} GB)."
  # Confirm we can read %USERPROFILE% before doing anything heavy.
  renderd_win_home >/dev/null \
    || die "couldn't resolve Windows %USERPROFILE% via cmd.exe."
}

# Install build deps lazily (only matters if user opted in).
renderd_install_build_deps() {
  case "$DISTRO_FAMILY" in
    fedora-like)
      # `dwarves` provides pahole (used during a normal kernel build for BTF
      # info). We disable BTF below to dodge a GCC 16 issue, but pahole's
      # presence keeps `make olddefconfig` happy. `flex`/`bison` are the
      # parser generators kernel headers need; `bc` is used by Kbuild.
      ui_spin "Install kernel build deps (dnf)" \
        sudo dnf install -y \
          gcc make bison flex bc \
          elfutils-libelf-devel openssl-devel \
          ncurses-devel python3 dwarves \
          rsync cpio xz tar perl
      ;;
    debian-like)
      export DEBIAN_FRONTEND=noninteractive
      ui_spin "Install kernel build deps (apt)" \
        sudo apt-get install -y --no-install-recommends \
          build-essential bison flex bc \
          libelf-dev libssl-dev libncurses-dev \
          python3 dwarves rsync cpio xz-utils tar perl
      ;;
  esac
}

# Resolve %USERPROFILE% as a /mnt/c/… path, via cmd.exe in the host.
# Echoes the unix path on stdout, returns non-zero if it can't.
renderd_win_home() {
  local raw
  # cmd.exe prints CRLF; strip both.
  raw=$(cd / && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')
  [ -n "$raw" ] || return 1
  wslpath -u "$raw"
}

# Pick the Microsoft kernel tag matching the running kernel version.
# `uname -r` looks like "6.18.26.1-microsoft-standard-WSL2" (or with our
# custom "+" suffix); strip everything after the first "-" to get the
# upstream version, prefix with linux-msft-wsl-.
renderd_pick_kernel_tag() {
  if [ -n "${RENDERD_TAG:-}" ]; then
    printf '%s\n' "$RENDERD_TAG"
    return 0
  fi
  local cur ver
  cur=$(uname -r)
  ver=${cur%%-*}
  # If parse failed for some reason, fall back to a known-good tag tested
  # with our config (2026-05-09).
  [ -n "$ver" ] || ver="6.18.26.1"
  printf 'linux-msft-wsl-%s\n' "$ver"
}

# Clone the kernel source. Skips if already there.
# If the chosen tag doesn't exist on Microsoft's repo, falls back to
# linux-msft-wsl-6.18.26.1 (last tag we've tested).
renderd_clone_source() {
  local tag=$1 srcdir=$2
  if [ -d "$srcdir/.git" ]; then
    ui_skip "Kernel source already at $srcdir"
    return 0
  fi
  if ui_spin "Clone microsoft/WSL2-Linux-Kernel ($tag)" \
       git clone --depth 1 --branch "$tag" \
         https://github.com/microsoft/WSL2-Linux-Kernel.git \
         "$srcdir"; then
    ui_detail "$srcdir"
    return 0
  fi
  ui_warn "Tag $tag not found; falling back to linux-msft-wsl-6.18.26.1"
  rm -rf "$srcdir"
  ui_spin "Clone fallback tag (linux-msft-wsl-6.18.26.1)" \
    git clone --depth 1 --branch linux-msft-wsl-6.18.26.1 \
      https://github.com/microsoft/WSL2-Linux-Kernel.git \
      "$srcdir" \
    || die "fallback clone also failed — check your internet connection."
  ui_detail "$srcdir"
}

# Apply our overlay on top of Microsoft's WSL config:
#   CONFIG_DRM_VKMS=y      — virtual KMS (provides /dev/dri/card1)
#   CONFIG_DRM_VGEM=y      — virtual GEM render node (/dev/dri/renderD128)
#   CONFIG_DEBUG_INFO_BTF=n
#                          — dodges a GCC 16.1.1 -Werror=discarded-qualifiers
#                            issue inside tools/bpf/resolve_btfids on Fedora 44.
#                            Cost: no in-kernel BTF info; harmless for our use.
renderd_apply_config() {
  local srcdir=$1
  [ -f "$srcdir/arch/x86/configs/config-wsl" ] \
    || die "arch/x86/configs/config-wsl missing in $srcdir — kernel layout changed?"
  ui_spin "Configure kernel (VKMS=y, VGEM=y, DEBUG_INFO_BTF=n)" bash -c '
    set -e
    cd "'"$srcdir"'"
    cp arch/x86/configs/config-wsl .config
    ./scripts/config --enable  CONFIG_DRM_VKMS
    ./scripts/config --enable  CONFIG_DRM_VGEM
    ./scripts/config --disable CONFIG_DEBUG_INFO_BTF
    # Normalize against the running source tree (resolves any new options
    # introduced since the WSL config was committed).
    make olddefconfig
  ' || die "kernel configuration failed"
}

# Build bzImage. Output is suppressed by ui_spin (only shows the spinner +
# label); on failure ui_spin dumps the last 20 lines under the ✗ for
# diagnosability. Build takes 5–10 min — the spinner is the user's signal
# that something's still happening.
renderd_build_kernel() {
  local srcdir=$1
  local jobs; jobs=$(nproc)
  # Cap at 8 to bound peak memory (kernel build LTO/link can spike).
  [ "$jobs" -gt 8 ] && jobs=8
  ui_spin "Build kernel (-j$jobs, ~5–10 min)" \
    make -C "$srcdir" -j"$jobs" bzImage \
    || die "kernel build failed — see last 20 lines above"
  [ -f "$srcdir/arch/x86/boot/bzImage" ] \
    || die "kernel build claimed success but arch/x86/boot/bzImage is missing"
}

# Copy the new bzImage to %USERPROFILE%\.wsl-kernel\bzImage, backing up
# any existing kernel at that path.
renderd_stage_bzimage() {
  local srcdir=$1
  local win_home; win_home=$(renderd_win_home) \
    || die "couldn't resolve %USERPROFILE%"
  local kernel_dir="$win_home/.wsl-kernel"
  local kernel_path="$kernel_dir/bzImage"

  mkdir -p "$kernel_dir"
  if [ -f "$kernel_path" ]; then
    cp "$kernel_path" "$kernel_path.before-wsl-gnome-rdp"
    ui_ok "Back up existing bzImage"
    ui_detail "$(wslpath -w "$kernel_path.before-wsl-gnome-rdp")"
  fi
  cp "$srcdir/arch/x86/boot/bzImage" "$kernel_path"
  ui_ok "Stage new bzImage"
  ui_detail "$(wslpath -w "$kernel_path")"

  renderd_patch_wslconfig "$win_home/.wslconfig" "$kernel_path"
}

# Edit %USERPROFILE%\.wslconfig to set kernel=… without clobbering the
# rest of the file. Backs up first. Four cases:
#   - file missing or empty        → create with [wsl2] + kernel=
#   - [wsl2] exists, kernel= line  → replace the line in-place
#   - [wsl2] exists, no kernel=    → insert kernel= just under the header
#   - no [wsl2] section at all     → append a new section at end
#
# Implementation note: we use awk (not sed -i) for edits because the
# kernel= value contains doubled backslashes, and sed's replacement-side
# treats `\\` as a literal `\` — so `sed s|.|kernel=C:\\\\bzImage|` would
# halve our escaping and produce a broken .wslconfig.
renderd_patch_wslconfig() {
  local wslconfig=$1 kernel_unix=$2
  # .wslconfig's INI parser accepts both single and double backslashes,
  # but the latter is what Microsoft's docs use and what existing tooling
  # (and our prior manual setup) emits — keep parity.
  local kernel_win
  kernel_win=$(wslpath -w "$kernel_unix" | sed 's/\\/\\\\/g')
  local target_line="kernel=$kernel_win"

  if [ -f "$wslconfig" ] && grep -Fxq "$target_line" "$wslconfig"; then
    ui_skip ".wslconfig already points at this bzImage"
    return 0
  fi
  if [ -f "$wslconfig" ]; then
    cp "$wslconfig" "$wslconfig.before-wsl-gnome-rdp"
    ui_ok "Back up existing .wslconfig"
    ui_detail "$(wslpath -w "$wslconfig.before-wsl-gnome-rdp")"
  fi

  if [ ! -s "$wslconfig" ]; then
    printf '[wsl2]\n%s\n' "$target_line" > "$wslconfig"
  elif grep -q '^\[wsl2\]' "$wslconfig"; then
    # awk: insert target right under [wsl2], drop any existing kernel=
    # line within the same section. We pass the target via ENVIRON, NOT
    # `-v target=…`, because `-v` interprets backslash escapes in the
    # assigned value (`\\` → `\`) which would halve our doubled
    # backslashes and produce a broken path.
    WSL_TARGET="$target_line" awk '
      /^\[wsl2\]/ { print; print ENVIRON["WSL_TARGET"]; in_section=1; next }
      /^\[/       { in_section=0 }
      in_section && /^kernel=/ { next }
      { print }
    ' "$wslconfig" > "$wslconfig.tmp" && mv "$wslconfig.tmp" "$wslconfig"
  else
    {
      # Ensure separating newline if file doesn't end in one.
      [ "$(tail -c1 "$wslconfig" 2>/dev/null)" != "" ] && echo
      printf '[wsl2]\n%s\n' "$target_line"
    } >> "$wslconfig"
  fi
  ui_ok "Patch .wslconfig"
  ui_detail "kernel=$kernel_win"
}

# Add user to video and render groups so Mesa can open /dev/dri/card0
# (group video) during EGL device enumeration. Without these groups Mesa
# silently drops the VGEM-backed device from eglQueryDevicesEXT and apps
# fall back to the software EGL device with a NULL render-node path.
# Effective on next login (or after `wsl --shutdown`, which we're about
# to ask the user to do anyway).
renderd_add_user_groups() {
  local need_video=1 need_render=1
  id -nG "$USER" | tr ' ' '\n' | grep -qx video  && need_video=0
  id -nG "$USER" | tr ' ' '\n' | grep -qx render && need_render=0
  if [ $need_video -eq 0 ] && [ $need_render -eq 0 ]; then
    ui_skip "$USER already in video+render groups"
    return 0
  fi
  ui_spin "Add $USER to video + render groups" \
    sudo usermod -aG video,render "$USER"
  ui_detail "effective on next login"
}

# Final, loud, in-your-face instruction. The build is useless until the
# user does this, so make it impossible to miss.
renderd_print_apply_instructions() {
  cat <<EOF

══════════════════════════════════════════════════════════════════
  Custom kernel staged. To apply, run from a Windows shell:

      wsl --shutdown

  …then re-launch this distro. Verify with:

      $PROJECT_ROOT/extras/renderd/verify.sh

  (or check by hand: \`ls /dev/dri/\` should show renderD128.)
══════════════════════════════════════════════════════════════════

EOF
}

# Public entry point — call from install.sh.
install_renderd_kernel() {
  prompt_renderd_optin || return 0

  ui_step "Custom kernel build"

  if renderd_already_active && [ "${INSTALL_RENDERD_FORCE:-0}" != "1" ]; then
    ui_skip "renderD128 is already exposed by the running kernel"
    ui_detail "set INSTALL_RENDERD_FORCE=1 to rebuild anyway"
    renderd_add_user_groups
    return 0
  fi

  renderd_preflight
  renderd_install_build_deps

  local tag srcdir
  tag=$(renderd_pick_kernel_tag)
  srcdir=${RENDERD_SRCDIR:-$HOME/.cache/wsl-gnome-rdp/WSL2-Linux-Kernel}
  mkdir -p "$(dirname "$srcdir")"

  renderd_clone_source     "$tag" "$srcdir"
  renderd_apply_config     "$srcdir"
  renderd_build_kernel     "$srcdir"
  renderd_stage_bzimage    "$srcdir"
  renderd_add_user_groups
  renderd_print_apply_instructions
}
