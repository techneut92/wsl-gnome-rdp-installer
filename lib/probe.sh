# lib/probe.sh — live GPU/GL/Vulkan probes shared by install.sh and
# diagnose.sh. install.sh installs the probe tools first (`mesa-demos` +
# `vulkan-tools`) then calls run_probes(); diagnose.sh calls run_probes
# directly (read-only — degrades gracefully if the tools aren't there).
#
# Both ends consume the results from these exported globals, set by
# run_probes():
#
#   DIAG_PROBED                 1 once run_probes has executed (cache flag)
#   DIAG_GL_D3D12_WORKS         1 if eglinfo via d3d12 returned a GL context
#   DIAG_GL_D3D12_RENDERER      the renderer string (e.g. "D3D12 (Intel Arc)")
#   DIAG_GL_LLVMPIPE_WORKS      1 if eglinfo via llvmpipe returned a GL context
#   DIAG_GL_LLVMPIPE_RENDERER   the renderer string
#   DIAG_VK_WORKS               1 if vulkaninfo --summary returned a device
#   DIAG_VK_IS_DZN              1 if the loaded Vulkan ICD is Mesa dzn
#   DIAG_VK_DRIVER              the Vulkan driverName string
#
# The pickers in lib/common.sh consult these to filter catastrophic-init
# failures. The Intel-Arc-Xe render-path bug (black screen with cursor
# only) doesn't manifest in eglinfo because eglinfo never paints a frame;
# the vendor heuristic (host_gpu_vendor) remains the source of truth for
# that case.

# Install eglinfo + vulkaninfo if missing. Only invoked by install.sh —
# diagnose.sh stays read-only and skips probes when the tools aren't
# present.
install_probe_tools() {
  ui_step "Probe tools"
  local missing=()
  command -v eglinfo    >/dev/null 2>&1 || missing+=(eglinfo)
  command -v vulkaninfo >/dev/null 2>&1 || missing+=(vulkaninfo)
  if [ ${#missing[@]} -eq 0 ]; then
    ui_skip "eglinfo + vulkaninfo already on PATH"
    return 0
  fi
  # Fedora packaging: `eglinfo` ships in `egl-utils` (NOT mesa-demos, which
  # is mostly libs/data with no CLI tools on f44). Debian/Ubuntu: `eglinfo`
  # is in `mesa-utils-extra`. `vulkaninfo` is `vulkan-tools` on both.
  case "$DISTRO_FAMILY" in
    fedora-like)
      ui_spin "Install egl-utils + vulkan-tools (dnf)" \
        sudo dnf install -y -q egl-utils vulkan-tools
      ;;
    debian-like)
      export DEBIAN_FRONTEND=noninteractive
      ui_spin "Install mesa-utils-extra + vulkan-tools (apt)" \
        sudo apt-get install -y -qq mesa-utils-extra vulkan-tools
      ;;
    *)
      ui_warn "no $DISTRO_FAMILY probe-tools recipe — probes will degrade"
      ;;
  esac
}

# Pure-bash field extractors — used by run_probes() so the probes don't
# depend on awk, which isn't guaranteed to be installed on a minimal
# image at this point in the pipeline (probes run BEFORE install_packages).
# grep + sed live in glibc-base; awk does not on Fedora minimal.

# extract_renderer <eglinfo-output>
# Echoes the value after `OpenGL [core profile ]renderer:`, or empty.
extract_renderer() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^OpenGL(\ core\ profile)?\ renderer:\ *(.+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[2]}"
      return 0
    fi
  done <<<"$1"
}

# extract_kv <vulkaninfo-output> <key>
# vulkaninfo --summary prints `<indent><key> = <value>`; echo the first value.
extract_kv() {
  local line key="$2"
  while IFS= read -r line; do
    if [[ "$line" =~ $key[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<<"$1"
}

# Run the probes once per process. Idempotent via DIAG_PROBED.
# Probes are wrapped in timeout(1) so a hung driver can't stall install.
run_probes() {
  [ "${DIAG_PROBED:-0}" = "1" ] && return 0

  DIAG_GL_D3D12_WORKS=0
  DIAG_GL_D3D12_RENDERER=""
  DIAG_GL_LLVMPIPE_WORKS=0
  DIAG_GL_LLVMPIPE_RENDERER=""
  DIAG_VK_WORKS=0
  DIAG_VK_IS_DZN=0
  DIAG_VK_DRIVER=""

  # Default platform (GBM via /dev/dri/renderD128 = vgem on WSL). eglinfo
  # creates a real GL context, so its "OpenGL core profile renderer:" line
  # tells us whether Mesa successfully loaded the requested gallium driver.
  # NOTE: probe init-success ≠ rendering correctness — the Intel-Arc-Xe
  # black-screen bug is in mutter's framebuffer round-trip and DOESN'T
  # surface in eglinfo. The vendor heuristic in pick_gallium_driver still
  # gates Intel even when this probe succeeds.
  # Use here-strings (<<<"$out") instead of `echo "$out" | grep -q`.
  # With `set -o pipefail`, grep -q exits as soon as it matches, the
  # large echo buffer flushing into the closed pipe gets SIGPIPE, and
  # pipefail propagates that as the pipe's exit status — making a
  # successful match look like a failed grep. Here-strings have no
  # writer process, so no SIGPIPE, no false failure.
  # Each probe is wrapped so a non-zero exit (timeout, segfault, no GL
  # context) can't trip install.sh's `set -e` and silently abort the run.
  # We inspect $out regardless of eglinfo's exit code — a crashed driver
  # is information, not a fatal error.
  ui_step "GL: d3d12 path"
  if command -v eglinfo >/dev/null 2>&1; then
    local out
    out=$(GALLIUM_DRIVER=d3d12 timeout 5 eglinfo 2>&1) || true
    # Pure bash extraction — awk isn't guaranteed to be installed yet
    # (probes run before install_packages). The renderer line looks like
    # `OpenGL core profile renderer: <name>` or `OpenGL renderer: <name>`.
    DIAG_GL_D3D12_RENDERER=$(extract_renderer "$out")
    if [ -n "$DIAG_GL_D3D12_RENDERER" ]; then
      DIAG_GL_D3D12_WORKS=1
      ui_ok "$DIAG_GL_D3D12_RENDERER"
    else
      ui_warn "no GL context — d3d12 init failed"
    fi
  else
    ui_skip "eglinfo not on PATH"
  fi

  ui_step "GL: llvmpipe path"
  if command -v eglinfo >/dev/null 2>&1; then
    local out
    out=$(LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
            timeout 5 eglinfo 2>&1) || true
    DIAG_GL_LLVMPIPE_RENDERER=$(extract_renderer "$out")
    if [ -n "$DIAG_GL_LLVMPIPE_RENDERER" ]; then
      DIAG_GL_LLVMPIPE_WORKS=1
      ui_ok "$DIAG_GL_LLVMPIPE_RENDERER"
    else
      ui_warn "no GL context — llvmpipe init failed (something is very wrong)"
    fi
  else
    ui_skip "eglinfo not on PATH"
  fi

  ui_step "Vulkan path"
  if command -v vulkaninfo >/dev/null 2>&1; then
    local vkout
    vkout=$(timeout 5 vulkaninfo --summary 2>&1) || true
    if grep -q 'apiVersion' <<<"$vkout"; then
      DIAG_VK_WORKS=1
      DIAG_VK_DRIVER=$(extract_kv "$vkout" driverName)
      if grep -qiE 'microsoft direct3d12|dzn' <<<"$vkout"; then
        DIAG_VK_IS_DZN=1
        ui_warn "$DIAG_VK_DRIVER (dzn — Mesa flags it 'testing use only')"
      else
        ui_ok "$DIAG_VK_DRIVER"
      fi
    else
      ui_warn "vulkaninfo: no device found"
    fi
  else
    ui_skip "vulkaninfo not on PATH"
  fi

  export DIAG_PROBED=1 \
         DIAG_GL_D3D12_WORKS DIAG_GL_D3D12_RENDERER \
         DIAG_GL_LLVMPIPE_WORKS DIAG_GL_LLVMPIPE_RENDERER \
         DIAG_VK_WORKS DIAG_VK_IS_DZN DIAG_VK_DRIVER
}
