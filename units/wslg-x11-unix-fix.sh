#!/bin/sh
# /usr/local/bin/wslg-x11-unix-fix — body of wslg-x11-unix-fix.service.
#
# Restores /tmp/.X11-unix to a writable mode-1777 directory so Mutter's
# Xwayland can bind its abstract sockets there. WSLg shadows /tmp/.X11-unix
# on every boot in one of two layouts the upstream pipeline has shipped:
#
#   - legacy: a symbolic link to /mnt/wslg/.X11-unix.
#   - newer (Ubuntu 26.04+): a read-only tmpfs (sometimes stacked twice)
#     containing WSLg's X0 socket.
#
# Both make Xwayland fail to start ("Directory \"/tmp/.X11-unix\" is missing
# the sticky bit" / "...is not writable"). When Xwayland fails,
# gnome-shell-headless falls into a SIGABRT restart loop and the RDP
# session stays dark — exactly the "Ubuntu black screen" reproduction
# in codeberg #2.
#
# Approach: don't try to umount what WSLg put down — on Ubuntu 26.04 the
# WSLg mount is visible from this distro but lives in a different mount
# namespace, and `umount` returns "not mounted" while `mountpoint -q`
# says it's a mountpoint. Instead, stack our own writable tmpfs over
# /tmp/.X11-unix; the kernel honours the top of the stack for new
# socket binds, and DISPLAY=:0 callers reach WSLg's X0 via the symlink
# we drop in afterwards. Idempotent — re-runs probe writability first.

set -e

# Legacy layout: replace the symlink with a directory before we can
# stack a tmpfs on it.
if [ -L /tmp/.X11-unix ]; then
  rm /tmp/.X11-unix
fi
if [ ! -d /tmp/.X11-unix ]; then
  mkdir -p /tmp/.X11-unix
fi

# Probe writability. If WSLg already presented a writable directory
# (some setups), or a previous invocation already stacked our tmpfs,
# nothing further needs to happen mount-side.
probe=/tmp/.X11-unix/.wslg-x11-unix-fix-probe
if touch "$probe" 2>/dev/null; then
  rm -f "$probe"
  # Make sure the sticky bit is set even on the happy path — Xwayland
  # specifically refuses 0777 without sticky. chmod is a no-op when
  # we're already at 1777.
  chmod 1777 /tmp/.X11-unix
else
  # Read-only underlying layer (ro tmpfs). Stack a writable tmpfs on
  # top — no umount needed, no namespace fight. mode=1777 is what
  # Xwayland looks for.
  mount -t tmpfs -o mode=1777 tmpfs /tmp/.X11-unix
fi

# Re-expose WSLg's X0 socket so DISPLAY=:0 inside the RDP session still
# reaches the host-side WSLg X server. Skip if X0 is already there from
# whatever was below (legitimate WSLg socket — leave it alone). Mutter's
# Xwayland will create X1/X2 in the same directory for its own session.
if [ ! -e /tmp/.X11-unix/X0 ] && [ -S /mnt/wslg/.X11-unix/X0 ]; then
  ln -s /mnt/wslg/.X11-unix/X0 /tmp/.X11-unix/X0
fi
