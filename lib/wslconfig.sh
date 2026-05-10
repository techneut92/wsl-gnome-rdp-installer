# lib/wslconfig.sh — keep the WSL2 VM alive after the last wsl.exe
# client exits, so gnome-shell-headless + grd survive the user closing
# the PowerShell window they used to boot the distro.
#
# Default WSL2 behavior is to shut the VM down ~60s after the last
# wsl.exe client exits, even with systemd services still running
# inside — the lifecycle is gated on attached clients, not on
# in-guest processes. Setting vmIdleTimeout=-1 in %USERPROFILE%\.wslconfig
# disables that idle shutdown so the RDP listener stays reachable
# across "close PowerShell" without needing a Windows Task Scheduler
# anchor.
#
# Idempotent. Preserves any existing keys/sections in .wslconfig.
# If vmIdleTimeout is already set (to anything — user override),
# the existing value is left alone.
#
# The change requires `wsl.exe --shutdown` to take effect, which the
# installer can't safely run on itself (it would tear down its own
# RDP session). On first install we emit a warning so the user knows
# to shutdown at their next convenient moment; subsequent re-runs
# detect the line already present and silently skip.

install_wslconfig_keepalive() {
  ui_step ".wslconfig keepalive"

  if ! command -v cmd.exe >/dev/null 2>&1; then
    ui_skip "cmd.exe not available (not WSL?) — skipping"
    return 0
  fi

  # Resolve Windows %USERPROFILE% → Linux path. `cd /` first because
  # Windows binaries invoked via binfmt fail with "Invalid argument"
  # when cwd is under a dot-prefixed path (e.g. ~/.local/share/...).
  local userprofile_win userprofile cfg
  userprofile_win=$(cd / && cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
  if [ -z "$userprofile_win" ]; then
    ui_warn "couldn't resolve %USERPROFILE% — skipping"
    ui_detail "VM will still shut down ~60s after last wsl.exe exits"
    return 0
  fi
  userprofile=$(wslpath -u "$userprofile_win" 2>/dev/null) || {
    ui_warn "wslpath -u '$userprofile_win' failed — skipping"
    return 0
  }
  cfg="$userprofile/.wslconfig"

  # If vmIdleTimeout is already set to anything, respect the user's
  # choice. They may have a deliberate non-default value (e.g. a long
  # explicit timeout for memory reclamation).
  if [ -f "$cfg" ] && grep -qiE '^[[:space:]]*vmIdleTimeout[[:space:]]*=' "$cfg"; then
    local current
    current=$(grep -iE '^[[:space:]]*vmIdleTimeout[[:space:]]*=' "$cfg" \
              | head -1 | sed 's/^[[:space:]]*//')
    ui_skip "vmIdleTimeout already configured"
    ui_detail "$cfg: $current"
    return 0
  fi

  # Splice vmIdleTimeout=-1 into [wsl2]. Section is created if absent;
  # insertion happens just before the next section header so the key
  # lands inside [wsl2] regardless of where that section sits in the
  # file. Other sections and comments are preserved verbatim.
  local tmp
  tmp=$(mktemp)
  if [ -f "$cfg" ]; then
    awk '
      BEGIN { in_wsl2 = 0; inserted = 0 }
      /^\[wsl2\][[:space:]]*$/ { print; in_wsl2 = 1; next }
      /^\[/ {
        if (in_wsl2 && !inserted) { print "vmIdleTimeout=-1"; inserted = 1 }
        in_wsl2 = 0
        print
        next
      }
      { print }
      END {
        if (!inserted) {
          if (!in_wsl2) print "[wsl2]"
          print "vmIdleTimeout=-1"
        }
      }
    ' "$cfg" > "$tmp"
  else
    printf '[wsl2]\nvmIdleTimeout=-1\n' > "$tmp"
  fi

  if [ -f "$cfg" ] && cmp -s "$cfg" "$tmp"; then
    rm -f "$tmp"
    ui_skip "no change needed"
    ui_detail "$cfg"
    return 0
  fi

  # Atomic replace. .wslconfig lives on DrvFs (NTFS via 9P), so a plain
  # `mv` is the safest portable approach — no fsync semantics to worry
  # about on a Windows-owned filesystem.
  mv "$tmp" "$cfg"
  ui_ok "Add vmIdleTimeout=-1 to $cfg"
  ui_detail "VM survives closing the PowerShell window with wsl"
  ui_warn "Run 'wsl.exe --shutdown' from Windows to apply (or reboot)"
  ui_detail "doing it now would terminate this install — defer until convenient"
  export _WSL_RDP_WSLCONFIG_CHANGED=1
}
