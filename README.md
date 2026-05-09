# wsl-gnome-rdp-installer

> ⚠️ **Experimental.** This stitches together gnome-shell-headless, gnome-remote-desktop, mutter's Xwayland, WSLg's quirks, and several systemd workarounds for upstream bugs. It works on the author's machine and is being iterated on as upstream packages move. Expect things to break in unexpected ways across distro upgrades, kernel updates, GNOME versions, or WSL/WSLg revisions. Read the script before running it. No warranty — see [LICENSE](LICENSE).

A scripted bootstrap for a **headless GNOME desktop inside a WSL2 distro**, served over RDP via `gnome-remote-desktop` so you can connect from the Windows host with `mstsc`.

Targets Fedora-like (`dnf`) and Debian-like (`apt`) distros. Idempotent — re-runs are safe.

```
Windows host                          WSL2 utility VM
─────────────                         ──────────────────────────────────
mstsc /v:localhost:3390  ─── RDP ───▶ gnome-remote-desktop-daemon (3390)
                                              │  Wayland (wayland-grd)
                                              ▼
                                       gnome-shell --headless --mode=user
                                              │  GALLIUM_DRIVER=d3d12
                                              ▼
                                       Mesa → D3D12 → DXG → host GPU
```

Multi-monitor works out of the box (`mstsc /multimon`) — `gnome-shell` is started without `--virtual-monitor`, so the RDP client supplies the monitor geometry on connect.

---

## Requirements

- Windows 10/11 with WSL2.
- A WSL2 distro (Fedora 40+, Ubuntu 24.04+, Debian 13+) with `systemd` enabled in `/etc/wsl.conf`:
  ```
  [boot]
  systemd=true
  ```
  Then `wsl --shutdown` from Windows so the change takes effect.
- A working RDP client on Windows — `mstsc` is fine.

---

## Install

In your WSL distro, as your normal user (sudo is used internally where needed):

```bash
git clone https://github.com/techneut92/wsl-gnome-rdp-installer.git
cd wsl-gnome-rdp-installer
./install.sh
```

The script will prompt for an RDP username + password the first time. Defaults to port `3390` (Windows already owns `3389` for its own RDP).

Then from Windows:

```
mstsc /v:localhost:3390
```

### Flags / env vars

| Flag | Env var          | Purpose |
|------|------------------|---------|
| `-u USERNAME` | `RDP_USERNAME` | RDP login username |
| `-p PASSWORD` | `RDP_PASSWORD` | RDP login password |
| `-P PORT`     | `RDP_PORT`     | RDP listen port (default: `3390`) |
| `-m`          | `INSTALL_DESKTOP=0` | Minimal: skip the full GNOME desktop app suite (Files, terminal, etc.) |
|               | `INSTALL_POP_SHELL=0` | Skip the Pop Shell tiling extension build |

---

## What you get

- **`gnome-shell-headless.service`** (user unit): Wayland compositor + GNOME UI, attaches to the RDP session.
- **`gnome-remote-desktop-headless.service`** (user unit): FreeRDP listener on the configured port.
- **Hardware-accelerated mutter** via `GALLIUM_DRIVER=d3d12` — Mesa's gallium d3d12 driver routes EGL through DXG to the host GPU. Verified at GL 4.6 against a real GPU device, vs the GL 4.5 llvmpipe fallback.
- **Multi-monitor RDP** via `mstsc /multimon` (no `--virtual-monitor` pinned).
- **TLS cert** auto-generated via `winpr-makecert` (preferred) or `openssl`.
- **User lingering** so the desktop survives shell logout.
- **Pop Shell** tiling extension, built from source and enabled.

### What you don't get (intentional WSL2 constraints)

- **No hardware video encode for RDP.** `gnome-remote-desktop` requires a non-NULL DRM render-node string from EGL, but `/dev/dri` doesn't exist on WSL2 distros. All grd hwaccel paths (NVENC, VA-API, Vulkan) bail and fall back to software RFX progressive. Mutter compositing is hardware; only the *encode* side is CPU.
- **No CUDA↔GL interop.** Microsoft only ships NVIDIA's compute libs (`libcuda`, `libnvidia-encode`) in `/usr/lib/wsl/lib/`, not `libGL_nvidia` / `libEGL_nvidia`. Nothing you can install fixes this on a stock WSL2 setup.

---

## Multi-distro support

Running two WSL2 distros side-by-side hits a sharp edge: WSL2 doesn't cgroup-namespace its distros, so every distro's PID 1 systemd targets the same cgroup path `/user.slice/user-$UID.slice/user@$UID.service/`. If both have a UID-1000 user (the WSL default), whichever distro boots second hits EBUSY and `user@$UID.service` fails to start:

```
Failed to spawn executor: Device or resource busy
user@$UID.service: Failed with result 'resources'.
```

This installer detects the collision (foreign-PID-namespace processes show as `0` in `cgroup.procs`) and offers to renumber the user via a oneshot systemd unit that runs at next boot, before login. It also:

- Picks the next free UID by scanning **both** `/etc/passwd` *and* the shared cgroup tree, so 3+ distros don't collide.
- Updates `/etc/wsl.conf` to `[user]default=$USERNAME` so the WSL launcher resolves your user by name (renumber-proof; otherwise `wsl -d <distro>` calls `getpwuid(OLD_UID)` → fails → drops you into root).
- Ships `units/wslg-pulse-detach.service` to detach WSLg's pre-created `/run/user/$UID/pulse → /mnt/wslg/runtime-dir/pulse` symlink (which is mode `0700` UID 1000, hardcoded by Microsoft) so `pipewire-pulse.socket` can bind on a renumbered UID.

The flow:

1. Run `./install.sh`. The collision check fires within ~1s.
2. Pick option 1 (recommended) — staged renumber + `/etc/wsl.conf` update.
3. From Windows: `wsl.exe -t <your-distro>` then reopen.
4. The oneshot unit runs at early boot, does the `usermod`/`groupmod`/`chown` (skipping `/mnt`, `/proc`, `/sys`, `/dev`, `/run`), disables itself.
5. Re-run `./install.sh` to finish the GNOME setup.

---

## Single-distro `systemd` 259 fix

On systemd 259 (Fedora 44 ships this), `Delegate=yes` services like `user@.service` hit a known kernel-cgroup-v2 EBUSY in `clone3(CLONE_INTO_CGROUP)` because of stale `subtree_control` entries (systemd issue #41278, fixed by PR #41304 in v261). The installer drops `/etc/systemd/system/user@.service.d/99-wsl-cgroup-fix.conf` with `DelegateSubgroup=` (empty) to sidestep it.

This is **distinct** from the multi-distro collision above — same symptom, different root cause. Both are handled.

---

## Repo layout

```
install.sh                                     entry point
lib/
  common.sh                                    log/distro detection
  packages.sh                                  dnf/apt packages, flatpaks
  cgroup_collision.sh                          multi-distro detect + UID renumber
  dbus.sh                                      systemd 259 drop-in + user-bus bootstrap
  cert.sh                                      TLS cert generation
  configure.sh                                 grdctl + systemd user units
  pop_shell.sh                                 Pop Shell build + enable
  verify.sh                                    end-of-run sanity check + summary
units/
  gnome-shell-headless.service                 user unit
  gnome-remote-desktop-headless.override.conf  software-EGL override for grd
  wslg-pulse-detach.service                    WSLg/renumber pulse fix
environment.d/
  10-wsl-gpu.conf                              GALLIUM_DRIVER=d3d12 for client apps
  20-gnome-session.conf                        XDG_CURRENT_DESKTOP / SESSION_TYPE
```

