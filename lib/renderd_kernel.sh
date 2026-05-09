# lib/renderd_kernel.sh — opt-in: build vgem.ko + vkms.ko as out-of-tree
# kernel modules against Microsoft's stock WSL kernel source, install
# under /lib/modules/$(uname -r)/extra/, and modprobe + persist via
# /etc/modules-load.d/ so /dev/dri/renderD128 appears.
#
# Why modules instead of a full kernel rebuild?
#   - Stock Microsoft WSL kernel ships CONFIG_DRM=y + CONFIG_MODULES=y,
#     so VGEM/VKMS slot in cleanly as out-of-tree modules.
#   - No .wslconfig kernel pinning — user keeps Microsoft's WSL kernel
#     updates flowing through normally.
#   - ~30–60s per-module build instead of 5–10 min full bzImage.
#   - No `wsl --shutdown` required — modprobe loads them immediately.
#
# Trade-off: when Microsoft pushes a new kernel via Microsoft Store,
# `uname -r` changes and our previously-built modules become vermagic-
# incompatible (load fails silently). Auto-rebuild handles this:
# install_renderd_kernel() detects "modules previously installed but
# missing for current kernel" and triggers a rebuild without prompting.
#
# What this still does NOT do:
#   - Add real GPU acceleration. VGEM is a virtual driver — apps still
#     render via llvmpipe (CPU). It only unblocks code paths that
#     disable themselves when no render node exists.
#   - Fix the chroma watermark in grd's RDP video stream — that needs
#     a separate gnome-remote-desktop source patch (see notes/
#     grd-vgem-journal-* in the author's local notes).
#
# Pipeline in install_renderd_kernel(), when INSTALL_RENDERD=1:
#   renderd_active && renderd_vkms_active && modules cached
#                                    → skip                │ short-path
#   renderd_fetch_prebuilt           → tarball from CI    │ ~5s, happy path
#       └ vermagic check + module_layout CRC vs MS stock  │ falls back on
#                                                            mismatch
#   renderd_local_build (fallback)
#       ├ renderd_preflight          → fail fast on disk
#       ├ renderd_install_build_deps                       │ heavy
#       ├ renderd_clone_or_refresh_source                  │ ↓
#       ├ renderd_apply_config       → VGEM=m, VKMS=m
#       └ renderd_build_modules      → full kernel build
#                                      LOCALVERSION="" + GCC-16 -Werror fix
#   renderd_install_modules          → /lib/modules/$(uname -r)/extra/
#   renderd_persist_load             → /etc/modules-load.d/wsl-renderd.conf
#   renderd_modprobe_now
#   renderd_add_user_groups          → video, render
#
# When INSTALL_RENDERD=0 but the persistence file exists (user
# de-selected after a previous opt-in), install_renderd_kernel()
# uninstalls cleanly via renderd_uninstall().
#
# Non-interactive overrides:
#   INSTALL_RENDERD_FORCE=1
#                        rebuild even if modules already match
#   RENDERD_LOCAL_BUILD=1
#                        skip prebuilt download, always build from source
#   RENDERD_PREBUILT_URL_BASE=…
#                        point at a fork's release host (testing/self-hosting)
#   RENDERD_SRCDIR=…     override clone location (default: ~/.cache/wsl-gnome-rdp/WSL2-Linux-Kernel)
#   RENDERD_TAG=…        override kernel tag (default: linux-msft-wsl-<uname -r prefix>)
#   RENDERD_JOBS=N       override -j parallelism for the local build (default: nproc)

RENDERD_LOAD_FILE=/etc/modules-load.d/wsl-renderd.conf
# /lib/modules/$(uname -r)/extra is the canonical drop-in dir for
# out-of-tree modules — depmod picks it up automatically.
renderd_modules_dir() { printf '%s\n' "/lib/modules/$(uname -r)/extra"; }

# Did the user previously opt in? Existence of our modules-load.d
# file is the durable signal — survives kernel bumps, distro reboots,
# install.sh re-runs.
renderd_user_opted_in() { [ -f "$RENDERD_LOAD_FILE" ]; }

# 0 = renderD128 already exposed (built-in OR loaded module), 1 = not.
# Sysfs is world-readable; works whether the kernel has VGEM=y in
# vmlinux or has loaded our vgem.ko module.
renderd_active() {
  [ -e /dev/dri/renderD128 ] || return 1
  local link
  link=$(readlink /sys/class/drm/renderD128 2>/dev/null) || return 1
  [[ $link == */vgem/* ]]
}

# Are vgem.ko + vkms.ko present for the running kernel?
renderd_modules_built_for_current_kernel() {
  local d; d=$(renderd_modules_dir)
  [ -f "$d/vgem.ko" ] && [ -f "$d/vkms.ko" ]
}

# 0 = vkms-backed /dev/dri/card1 already exposed, 1 = not.
# Microsoft's stock kernel ships vgem.ko on recent versions, so
# `renderd_active` (renderD128) being true is no longer enough to
# conclude "we have nothing to do" — vkms is the actually-missing piece.
renderd_vkms_active() {
  [ -e /dev/dri/card1 ] || return 1
  local link
  link=$(readlink /sys/class/drm/card1 2>/dev/null) || return 1
  [[ $link == */vkms/* ]]
}

# Strong sanity check on a candidate .ko before we install it:
# vermagic alone isn't enough — CRCs on `module_layout` (the symbol that
# encodes struct module's ABI) can differ between our build and MS's even
# when vermagic matches, e.g. if BTF was disabled on our side. We compare
# our .ko's module_layout CRC against MS's stock vgem.ko's, when present.
# Returns 0 if compatible (or no reference module available), 1 if not.
renderd_verify_module_compat() {
  local ko=$1
  local stock_vgem="/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/vgem/vgem.ko"
  [ -f "$stock_vgem" ] || return 0   # nothing to compare against
  command -v modprobe >/dev/null || return 0
  local ours stock
  ours=$(modprobe --dump-modversions  "$ko"        2>/dev/null \
           | awk '$2=="module_layout"{print $1; exit}')
  stock=$(modprobe --dump-modversions "$stock_vgem" 2>/dev/null \
           | awk '$2=="module_layout"{print $1; exit}')
  [ -n "$ours" ] && [ -n "$stock" ] && [ "$ours" = "$stock" ]
}

# Pre-build sanity. Fails fast before we burn build time.
renderd_preflight() {
  command -v git >/dev/null \
    || die "git missing — should have been pulled in by install_packages"
  # Modules-only build needs ≥ 2 GB (source ~1.5 GB + tooling).
  local free_gb
  free_gb=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4+0}')
  [ -n "$free_gb" ] && [ "$free_gb" -ge 2 ] \
    || die "Need ≥ 2 GB free in \$HOME for kernel source (have ${free_gb:-?} GB)."
}

renderd_install_build_deps() {
  case "$DISTRO_FAMILY" in
    fedora-like)
      ui_spin "Install kernel-module build deps (dnf)" \
        sudo dnf install -y \
          gcc make bison flex bc \
          elfutils-libelf-devel openssl-devel \
          ncurses-devel python3 dwarves \
          rsync cpio xz tar perl
      ;;
    debian-like)
      export DEBIAN_FRONTEND=noninteractive
      ui_spin "Install kernel-module build deps (apt)" \
        sudo apt-get install -y --no-install-recommends \
          build-essential bison flex bc \
          libelf-dev libssl-dev libncurses-dev \
          python3 dwarves rsync cpio xz-utils tar perl
      ;;
  esac
}

# Pick Microsoft's tag matching `uname -r`. With modules-only, this
# is critical — the modules' vermagic must match the running kernel
# exactly or `modprobe` rejects them.
renderd_pick_kernel_tag() {
  if [ -n "${RENDERD_TAG:-}" ]; then
    printf '%s\n' "$RENDERD_TAG"
    return 0
  fi
  local cur ver
  cur=$(uname -r)
  ver=${cur%%-*}
  [ -n "$ver" ] || ver="6.18.26.1"
  printf 'linux-msft-wsl-%s\n' "$ver"
}

# Clone or refresh source. If the cached source's checked-out tag
# doesn't match what we want, blow away and re-clone — shallow clones
# can't easily switch tags.
renderd_clone_or_refresh_source() {
  local tag=$1 srcdir=$2
  if [ -d "$srcdir/.git" ]; then
    local current_tag
    current_tag=$(git -C "$srcdir" describe --tags --exact-match 2>/dev/null) || current_tag=""
    if [ "$current_tag" = "$tag" ]; then
      ui_skip "Source already at $tag ($srcdir)"
      return 0
    fi
    ui_detail "cached source is on $current_tag, switching to $tag"
    rm -rf "$srcdir"
  fi
  if ! ui_spin "Clone microsoft/WSL2-Linux-Kernel ($tag)" \
         git clone --depth 1 --branch "$tag" \
           https://github.com/microsoft/WSL2-Linux-Kernel.git \
           "$srcdir"; then
    ui_warn "Tag $tag not found; falling back to linux-msft-wsl-6.18.26.1"
    rm -rf "$srcdir"
    ui_spin "Clone fallback tag" \
      git clone --depth 1 --branch linux-msft-wsl-6.18.26.1 \
        https://github.com/microsoft/WSL2-Linux-Kernel.git \
        "$srcdir" \
      || die "fallback clone also failed — check your internet connection."
  fi
}

# Apply our overlay on top of Microsoft's WSL config:
#   CONFIG_DRM_VKMS=m  — virtual KMS (/dev/dri/card1)
#   CONFIG_DRM_VGEM=m  — virtual GEM render node (/dev/dri/renderD128).
#                        Already shipped =m by Microsoft on recent kernels
#                        (6.6.114.1+); kept here so older kernels still
#                        get coverage and so /lib/modules/.../extra has a
#                        CRC-matching backup if MS ever drops it.
#   CONFIG_DRM_GEM_SHMEM_HELPER=m  — VKMS dep, ensure available as module.
#
# We intentionally KEEP CONFIG_DEBUG_INFO_BTF=y. Microsoft ships its kernel
# with CONFIG_DEBUG_INFO_BTF_MODULES=y, which adds two fields (btf_data,
# btf_data_size) to `struct module`. Disabling BTF here changes struct
# module's layout, which changes every module CRC including module_layout
# — vkms.ko built without BTF gets rejected by Microsoft's running kernel
# with "disagrees about version of symbol module_layout" even though
# vermagic matches. The HOSTCFLAGS workaround in renderd_build_modules
# handles the GCC-16 -Werror that previously motivated the BTF disable.
#
# Note: =m, NOT =y. We're building modules, not patching the kernel.
renderd_apply_config() {
  local srcdir=$1
  [ -f "$srcdir/arch/x86/configs/config-wsl" ] \
    || die "arch/x86/configs/config-wsl missing in $srcdir — kernel layout changed?"
  ui_spin "Configure kernel (VGEM=m, VKMS=m, BTF kept on)" bash -c '
    set -e
    cd "'"$srcdir"'"
    cp arch/x86/configs/config-wsl .config
    ./scripts/config --module  CONFIG_DRM_VGEM
    ./scripts/config --module  CONFIG_DRM_VKMS
    ./scripts/config --module  CONFIG_DRM_GEM_SHMEM_HELPER
    make olddefconfig
  ' || die "kernel module configuration failed"
}

# Build vgem.ko + vkms.ko in-tree. `make modules_prepare` alone doesn't
# emit Module.symvers, and without that modpost can't resolve symbols
# (kfree, drm_*, …) and bails. The default `make` target does the full
# vmlinux + modules build; .ko's land in their driver dirs as a side
# effect. Slow (~5–10 min) — most users get the prebuilt instead, this
# is the fallback for offline / custom-kernel / no-prebuilt cases.
#
# LOCALVERSION="" tells scripts/setlocalversion to skip its SCM-suffix
# branch. Otherwise it appends `+` to UTS_RELEASE because Microsoft tags
# as `linux-msft-wsl-X.Y.Z.W` (not `vX.Y.Z`), and modprobe rejects the
# resulting `…-WSL2+` vermagic against the stock `…-WSL2` running kernel.
#
# HOSTCFLAGS=-Wno-error=discarded-qualifiers works around a strchr()
# const-cast in tools/bpf/resolve_btfids/libbpf/libbpf.c that newer GCCs
# (≥16) flag fatal under host-side -Werror. Older GCCs don't warn;
# applying unconditionally is harmless.
renderd_build_modules() {
  local srcdir=$1
  local jobs=${RENDERD_JOBS:-$(nproc)}
  ui_spin "Build kernel + modules (-j$jobs, ~5–10 min)" \
    make -C "$srcdir" -j"$jobs" \
         LOCALVERSION="" \
         HOSTCFLAGS="-Wno-error=discarded-qualifiers" \
    || die "kernel/module build failed"
  [ -f "$srcdir/drivers/gpu/drm/vgem/vgem.ko" ] \
    || die "vgem.ko missing after build"
  [ -f "$srcdir/drivers/gpu/drm/vkms/vkms.ko" ] \
    || die "vkms.ko missing after build"
}

# Drop the .ko files into /lib/modules/$(uname -r)/extra and run
# depmod so modprobe can find them. depmod's index keys off uname -r,
# so the modules become "the modules for this kernel" — if Microsoft
# bumps the kernel, our modules vanish from the index and renderD128
# stops appearing on next boot, prompting the auto-rebuild.
#
# Args: vgem.ko path, vkms.ko path. Both paths are read by sudo; the
# files just need to be readable to whoever runs install.sh.
renderd_install_modules() {
  local vgem_ko=$1 vkms_ko=$2
  local target_dir; target_dir=$(renderd_modules_dir)
  ui_spin "Install vgem.ko + vkms.ko → $target_dir" bash -c "
    set -e
    sudo install -d -m 755 '$target_dir'
    sudo install -m 644 '$vgem_ko' '$target_dir/vgem.ko'
    sudo install -m 644 '$vkms_ko' '$target_dir/vkms.ko'
    sudo depmod -a \"\$(uname -r)\"
  "
}

# Try to download prebuilt modules from the wsl-renderd-modules repo
# matching the running kernel. On success, sets RENDERD_PREBUILT_VGEM
# and RENDERD_PREBUILT_VKMS to the extracted .ko paths and returns 0.
# On any failure, returns 1 (caller falls back to local build).
#
# Override the source repo via RENDERD_PREBUILT_URL_BASE — useful when
# self-hosting or testing from a fork.
renderd_fetch_prebuilt() {
  local tag short url tmpdir
  tag=$(renderd_pick_kernel_tag)
  short=${tag#linux-msft-wsl-}
  url="${RENDERD_PREBUILT_URL_BASE:-https://github.com/techneut92/wsl-renderd-modules/releases/download}"
  url="$url/$tag/vgem-vkms-modules-$short.tar.gz"

  tmpdir=$(mktemp -d)
  if ! ui_spin "Fetch prebuilt modules ($tag)" \
        curl -fLsS -o "$tmpdir/pkg.tar.gz" "$url"; then
    ui_detail "no prebuilt available — will build locally"
    rm -rf "$tmpdir"
    return 1
  fi

  if ! tar -xzf "$tmpdir/pkg.tar.gz" -C "$tmpdir" --strip-components=1 2>/dev/null; then
    ui_warn "Downloaded artifact isn't a valid tarball"
    rm -rf "$tmpdir"
    return 1
  fi
  if [ ! -f "$tmpdir/vgem.ko" ] || [ ! -f "$tmpdir/vkms.ko" ]; then
    ui_warn "Downloaded artifact missing expected .ko files"
    rm -rf "$tmpdir"
    return 1
  fi

  # vermagic must match the running kernel exactly or modprobe will
  # refuse to load. modinfo's first whitespace-delimited field is
  # the kernel release string.
  local expected got
  expected=$(uname -r)
  got=$(modinfo -F vermagic "$tmpdir/vgem.ko" 2>/dev/null | awk '{print $1}')
  if [ -z "$got" ] || [ "$got" != "$expected" ]; then
    ui_warn "Prebuilt vermagic mismatch: got '${got:-?}', need '$expected'"
    ui_detail "this happens if you're on a custom kernel (uname -r ends in '+')"
    ui_detail "or if Microsoft's tag-builds haven't reached your kernel yet"
    rm -rf "$tmpdir"
    return 1
  fi
  ui_detail "vermagic verified ($got)"

  # CRC sanity. Vermagic match doesn't prove the modules will load —
  # CRCs on module_layout (struct module's ABI marker) can still differ
  # if the prebuilt was made with a config option that changed struct
  # module's layout (e.g. CONFIG_DEBUG_INFO_BTF_MODULES toggled). When
  # MS ships a stock vgem.ko we can compare directly against it.
  if ! renderd_verify_module_compat "$tmpdir/vgem.ko"; then
    ui_warn "Prebuilt module_layout CRC differs from stock kernel's"
    ui_detail "modprobe would reject these — falling back to local build"
    rm -rf "$tmpdir"
    return 1
  fi

  RENDERD_PREBUILT_VGEM="$tmpdir/vgem.ko"
  RENDERD_PREBUILT_VKMS="$tmpdir/vkms.ko"
  RENDERD_PREBUILT_TMPDIR="$tmpdir"
  export RENDERD_PREBUILT_VGEM RENDERD_PREBUILT_VKMS RENDERD_PREBUILT_TMPDIR
  return 0
}

# Local build path — fallback when prebuilt download fails.
# Produces vgem.ko + vkms.ko inside $srcdir's drivers tree.
renderd_local_build() {
  local srcdir=$1
  renderd_preflight
  renderd_install_build_deps
  local tag
  tag=$(renderd_pick_kernel_tag)
  renderd_clone_or_refresh_source "$tag" "$srcdir"
  renderd_apply_config            "$srcdir"
  renderd_build_modules           "$srcdir"
}

# Persist module loading across boots. systemd-modules-load.service
# reads /etc/modules-load.d/*.conf at boot and modprobes each name.
renderd_persist_load() {
  sudo install -d -m 755 /etc/modules-load.d
  printf 'vgem\nvkms\n' | sudo tee "$RENDERD_LOAD_FILE" >/dev/null
  ui_ok "Persist modprobe at boot"
  ui_detail "$RENDERD_LOAD_FILE"
}

renderd_modprobe_now() {
  ui_spin "modprobe vgem + vkms" bash -c '
    sudo modprobe vgem && sudo modprobe vkms
  ' || die "modprobe failed — see output above. Modules built but not loadable; check `sudo dmesg | tail`."
}

# Add user to video and render groups so Mesa can open /dev/dri/card0
# during EGL device enumeration. Without these groups Mesa silently
# drops the VGEM device from eglQueryDevicesEXT.
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

# Clean uninstall path — fired when the user de-selects the renderd
# box in the menu after previously opting in.
renderd_uninstall() {
  ui_step "renderd modules: uninstall"
  ui_spin "rmmod vkms + vgem (if loaded)" bash -c '
    sudo rmmod vkms 2>/dev/null || true
    sudo rmmod vgem 2>/dev/null || true
  '
  local d; d=$(renderd_modules_dir)
  if [ -f "$d/vgem.ko" ] || [ -f "$d/vkms.ko" ]; then
    ui_spin "Remove .ko files + depmod" bash -c '
      sudo rm -f "'"$d"'"/vgem.ko "'"$d"'"/vkms.ko
      sudo depmod -a "$(uname -r)"
    '
  fi
  if [ -f "$RENDERD_LOAD_FILE" ]; then
    sudo rm -f "$RENDERD_LOAD_FILE"
    ui_ok "Remove $RENDERD_LOAD_FILE"
  fi
}

# Public entry point — call from install.sh.
#
# Three branches:
#   1. INSTALL_RENDERD=1 + already active + modules current →
#      no-op (idempotent re-run).
#   2. INSTALL_RENDERD=1 + (inactive OR stale) → build + install.
#   3. INSTALL_RENDERD=0 + previously opted in → uninstall.
install_renderd_kernel() {
  if [ "${INSTALL_RENDERD:-0}" != "1" ]; then
    if renderd_user_opted_in; then
      renderd_uninstall
    fi
    return 0
  fi

  ui_step "renderd modules"

  # Short-path: BOTH /dev/dri/renderD128 (vgem) and /dev/dri/card1 (vkms)
  # already there, AND our .ko's are present in extra/ for the running
  # kernel. Nothing to do — unless FORCE is set.
  if renderd_active && renderd_vkms_active \
     && renderd_modules_built_for_current_kernel \
     && [ "${INSTALL_RENDERD_FORCE:-0}" != "1" ]; then
    ui_skip "vgem + vkms current and active for $(uname -r)"
    renderd_add_user_groups
    return 0
  fi

  # Pre-existing custom-kernel install (VGEM=y in vmlinux) — vermagic
  # has '+', our prebuilts can't match, and there's no card1 path here
  # since the user's kernel was rebuilt before we shipped vkms support.
  # Don't touch.
  if renderd_active && ! renderd_user_opted_in \
     && [[ "$(uname -r)" == *+* ]] \
     && [ "${INSTALL_RENDERD_FORCE:-0}" != "1" ]; then
    ui_skip "custom kernel + renderD128 present (not installed by us — leaving alone)"
    ui_detail "remove your .wslconfig kernel= pin to switch to module-mode"
    renderd_add_user_groups
    return 0
  fi

  # Need to install. Cases that land here:
  #   - first-time opt-in, nothing loaded
  #   - first-time opt-in, MS-shipped vgem already there but vkms missing
  #   - kernel-bump auto-rebuild (opted in but modules vanished)
  #   - INSTALL_RENDERD_FORCE=1
  if renderd_user_opted_in && ! renderd_modules_built_for_current_kernel; then
    ui_warn "Kernel bumped to $(uname -r) — fetching/building modules to match"
  fi
  if renderd_active && ! renderd_vkms_active; then
    ui_detail "stock kernel ships vgem (renderD128 present); installing our vkms for /dev/dri/card1"
  fi

  # Try the prebuilt path first (5–10s download vs. 60–90s local build).
  # Falls back to local build on any failure: 404, network down, version
  # mismatch (custom kernel), checksum/format issue.
  local vgem_ko vkms_ko
  if [ "${RENDERD_LOCAL_BUILD:-0}" != "1" ] && renderd_fetch_prebuilt; then
    vgem_ko="$RENDERD_PREBUILT_VGEM"
    vkms_ko="$RENDERD_PREBUILT_VKMS"
  else
    [ "${RENDERD_LOCAL_BUILD:-0}" = "1" ] \
      && ui_detail "RENDERD_LOCAL_BUILD=1 — skipping prebuilt download"
    local srcdir
    srcdir=${RENDERD_SRCDIR:-$HOME/.cache/wsl-gnome-rdp/WSL2-Linux-Kernel}
    mkdir -p "$(dirname "$srcdir")"
    renderd_local_build "$srcdir"
    vgem_ko="$srcdir/drivers/gpu/drm/vgem/vgem.ko"
    vkms_ko="$srcdir/drivers/gpu/drm/vkms/vkms.ko"
  fi

  renderd_install_modules "$vgem_ko" "$vkms_ko"
  [ -n "${RENDERD_PREBUILT_TMPDIR:-}" ] && rm -rf "$RENDERD_PREBUILT_TMPDIR"
  renderd_persist_load
  renderd_modprobe_now
  renderd_add_user_groups

  if renderd_active && renderd_vkms_active; then
    ui_ok "vgem + vkms ready"
    ui_detail "/dev/dri/renderD128 (vgem) + /dev/dri/card1 (vkms)"
  elif renderd_active; then
    ui_warn "vgem loaded but vkms didn't — /dev/dri/card1 missing"
    ui_detail "check: ls /dev/dri/  &&  sudo dmesg | tail"
  else
    ui_warn "modprobe completed but /dev/dri/renderD128 not present yet"
    ui_detail "check: ls /dev/dri/  &&  sudo dmesg | tail"
  fi
}
