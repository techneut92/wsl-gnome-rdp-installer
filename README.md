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

All interaction happens upfront, inline (no full-screen TUI):

1. **RDP credentials** — username (defaults to `$USER`), then password asked twice for confirmation. Empty or mismatched re-prompts. On a re-run where `gnome-remote-desktop` already has stored credentials, this is silently skipped (pass `-u`/`-p` to force a change).
2. **Component checklist** (arrow keys to navigate, space to toggle, enter to confirm, q/esc to cancel):
   - GNOME desktop apps (Files, terminal, …)
   - Firefox (flatpak, flathub)
   - ONLYOFFICE (flatpak, flathub)
   - Pop Shell tiling extension
   - Custom kernel for `/dev/dri/renderD128` (~10 min build, opt-in)

   AppIndicator system-tray extension is mandatory (always installed) — apps that only present a tray icon (jetbrains-toolbox is the headline case) silently exit without it.

Defaults to port `3390` (Windows already owns `3389` for its own RDP).

After the prompts, the rest of the run is uninterrupted — packages, units, certs, services. Then from Windows:

```
mstsc /v:localhost:3390
```

### Where install.sh actually lives

The first run from a clone bootstraps the installer to `~/.local/share/wsl-gnome-rdp-installer/` (override with `WSL_RDP_INSTALL_DIR`) and re-execs from there. The `wsl-rdp-gnome-renew` shim and all subsequent runs operate on that stable location, so the renew flow doesn't depend on wherever the user happens to keep their clone.

### Re-running / self-update

The installer drops a `wsl-rdp-gnome-renew` shim into `/usr/local/bin/` on first run. To re-run with the latest from upstream:

```bash
wsl-rdp-gnome-renew
```

This `git fetch` + `git pull --ff-only` in `~/.local/share/wsl-gnome-rdp-installer/` against `origin/HEAD`, then re-execs the updated script. The shim sets `RESET_DIRTY=1` so any local edits in the install dir are clobbered before pulling — invoking renew explicitly means "give me upstream".

Skipped automatically when:

- there's no upstream tracking branch (fork without `git push -u`),
- fetch fails (offline / no auth — warns and continues with the local copy).

Running `./install.sh` directly from your clone (instead of the renew shim) preserves working-tree edits — pass `RESET_DIRTY=1` manually to override that.

Every step is idempotent, so re-running after an upstream fix is safe — already-good steps render `∼ already …` instead of redoing the work.

### Flags / env vars

Set any `INSTALL_*` env var to `0`/`1` and the matching component box in the upfront menu starts pre-checked or pre-unchecked accordingly — useful when you want to reuse the same defaults across re-runs without clicking through the menu.

| Flag | Env var          | Purpose |
|------|------------------|---------|
| `-u USERNAME` | `RDP_USERNAME` | RDP login username (skips the username prompt) |
| `-p PASSWORD` | `RDP_PASSWORD` | RDP login password (skips the password + confirm prompts) |
| `-P PORT`     | `RDP_PORT`     | RDP listen port (default: `3390`) |
| `-m`          | (sets `INSTALL_DESKTOP=0` and `INSTALL_FLATPAK=0`) | Minimal: pre-uncheck the GNOME desktop + flatpak boxes in the menu |
|               | `INSTALL_DESKTOP=0/1`     | Pre-check the GNOME desktop apps box |
|               | `INSTALL_FLATPAK=0/1`     | Pre-check the flatpak apps box |
|               | `INSTALL_POP_SHELL=0/1`   | Pre-check the Pop Shell box |
|               | `INSTALL_APPINDICATOR=0/1` | Pre-check the AppIndicator box |
|               | `INSTALL_RENDERD=0/1`     | Pre-check the custom-kernel box (see [Optional: custom kernel for `/dev/dri/renderD128`](#optional-custom-kernel-for-devdrirenderd128)) |

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

## Optional: custom kernel for `/dev/dri/renderD128`

The component checklist at the start of the run includes a "Custom kernel for `/dev/dri/renderD128`" box. It's pre-unchecked by default — tick it to opt in, or pre-set `INSTALL_RENDERD=1` to have it pre-checked. The build runs LAST in the pipeline so even if it fails, the rest of the desktop already came up.

**Why you might want it.** Microsoft's stock WSL kernel ships no DRM device at all, so any Linux app that gates a feature on a render node existing silently disables that feature. Adding VGEM unblocks:

- **PipeWire dma-buf screen capture** — `xdg-desktop-portal-gnome` screencast, OBS Studio's PipeWire source, browser screen-share via PipeWire.
- **EGL device-platform consumers** — gstreamer's GL pipeline, ffmpeg's `egl` source, headless rendering test harnesses.
- **Wayland clients that probe DRI before flipping to Wayland mode** — some Electron apps (Slack, Discord, VS Code with `--ozone-platform=wayland`), nested Wayland compositors, some games.
- **Browsers' GPU sandboxing checks** — Firefox WebRender will at least *try* the hardware-decode codepath instead of disabling it outright.

**What it does NOT do.**

- Does **not** add real GPU acceleration. VGEM is a virtual driver — apps still render via llvmpipe (CPU). It only unblocks codepaths that disable themselves when no render node exists.
- Does **not** fix the chroma watermark in the RDP video stream. That's a separate problem in `gnome-remote-desktop`'s EGL gate that the kernel rebuild alone doesn't unlock; see the comment block in `lib/renderd_kernel.sh` for the three-layer analysis.
- Does **not** help apps that already work via WSLg's relay (those use Microsoft's own dma-buf path through `/mnt/wslg/`).

**Cost.**

- 5–10 min build time (uses up to 8 cores).
- ~500 MB of build dependencies (`gcc`, `make`, `bison`, `flex`, `libelf-dev`, etc.) installed temporarily.
- Requires `wsl --shutdown` from Windows to apply.
- Reversible: your `.wslconfig` is backed up to `.wslconfig.before-wsl-gnome-rdp` before being modified, and any pre-existing `bzImage` is preserved as `bzImage.before-wsl-gnome-rdp`.

**After installing**, run `wsl --shutdown` from a Windows shell, re-launch the distro, and verify with:

```bash
./extras/renderd/verify.sh
```

which prints PASS/FAIL for each of: VGEM is the active driver, `/dev/dri/renderD128` exists, `.wslconfig` points at the new kernel, your user is in the `video` and `render` groups.

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
  ui.sh                                        colors, headers, ui_spin
  common.sh                                    log/distro detection
  prompt.sh                                    upfront credential + component prompts (whiptail)
  packages.sh                                  dnf/apt packages, flatpaks
  cgroup_collision.sh                          multi-distro detect + UID renumber
  dbus.sh                                      systemd 259 drop-in + user-bus bootstrap
  cert.sh                                      TLS cert generation
  configure.sh                                 grdctl + systemd user units
  pop_shell.sh                                 Pop Shell build + enable
  renderd_kernel.sh                            opt-in custom kernel for /dev/dri/renderD128
  verify.sh                                    end-of-run sanity check + summary
extras/
  renderd/
    verify.sh                                  post-`wsl --shutdown` checks for the custom kernel
units/
  gnome-shell-headless.service                 user unit
  gnome-remote-desktop-headless.override.conf  software-EGL override for grd
  wslg-pulse-detach.service                    WSLg/renumber pulse fix
environment.d/
  10-wsl-gpu.conf                              GALLIUM_DRIVER=d3d12 for client apps
  20-gnome-session.conf                        XDG_CURRENT_DESKTOP / SESSION_TYPE
```

