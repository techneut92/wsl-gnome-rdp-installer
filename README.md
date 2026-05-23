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
                                              │  GALLIUM_DRIVER=d3d12 (NVIDIA/AMD)
                                              │  GALLIUM_DRIVER=llvmpipe (Intel iGPU)
                                              ▼
                                       Mesa → D3D12 → DXG → host GPU
                                       (or pure software on Intel — see below)
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
git clone https://codeberg.org/techneut92/wsl-gnome-rdp-installer.git
cd wsl-gnome-rdp-installer
./install.sh
```

Before installing (or to triage a broken install afterwards), run the read-only probe to see what's detected and which auto-detected choices the installer would make on your box:

```bash
./diagnose.sh        # full report
./diagnose.sh -q     # skip live GL/Vulkan probes
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
|               | `INSTALL_ANCHOR=0/1`      | Pre-check the persistence-anchor box (see [Optional: persist the distro across closing the shell](#optional-persist-the-distro-across-closing-the-shell)) — default OFF |

---

## What you get

- **`gnome-shell-headless.service`** (user unit): Wayland compositor + GNOME UI, attaches to the RDP session.
- **`gnome-remote-desktop-headless.service`** (user unit): FreeRDP listener on the configured port.
- **Hardware-accelerated mutter** via `GALLIUM_DRIVER=d3d12` — Mesa's gallium d3d12 driver routes EGL through DXG to the host GPU. Verified at GL 4.6 against a real GPU device, vs the GL 4.5 llvmpipe fallback. **Intel iGPUs (Meteor Lake Arc Xe) auto-fall-back to `llvmpipe`** — the d3d12 path produces a black-screen-with-cursor over RDP on that hardware. Override with `WSL_RDP_GALLIUM_DRIVER={auto,d3d12,llvmpipe}`.
- **Multi-monitor RDP** via `mstsc /multimon` (no `--virtual-monitor` pinned).
- **TLS cert** auto-generated via `winpr-makecert` (preferred) or `openssl`.
- **User lingering** so the desktop survives shell logout.
- **Pop Shell** tiling extension, built from source and enabled.

### What you don't get (intentional WSL2 constraints)

- **No hardware video encode for RDP.** `gnome-remote-desktop` requires a non-NULL DRM render-node string from EGL, but `/dev/dri` doesn't exist on WSL2 distros. All grd hwaccel paths (NVENC, VA-API, Vulkan) bail and fall back to software RFX progressive. Mutter compositing is hardware; only the *encode* side is CPU.
- **No CUDA↔GL interop.** Microsoft only ships NVIDIA's compute libs (`libcuda`, `libnvidia-encode`) in `/usr/lib/wsl/lib/`, not `libGL_nvidia` / `libEGL_nvidia`. Nothing you can install fixes this on a stock WSL2 setup.

---

## Render node modules (`/dev/dri/renderD128`)

The component checklist defaults the **"Custom kernel for /dev/dri/renderD128"** box to ON. Microsoft's stock WSL kernel ships `CONFIG_DRM=y` but no `VGEM`/`VKMS`, so apps that gate features on a DRM render node existing silently disable themselves. We fix that by `modprobe`'ing two out-of-tree modules — no `.wslconfig` change, no kernel pin, no `wsl --shutdown` required.

**Modules come from the [wsl-renderd-modules](https://github.com/techneut92/wsl-renderd-modules) companion repo,** which builds them in CI against each Microsoft WSL kernel tag and publishes the result as a GitHub Release. The installer picks the matching tarball, verifies vermagic, and drops the .ko's into `/lib/modules/$(uname -r)/extra/`. A 5-second download, end-to-end. If the prebuilt isn't available (offline / no matching artifact yet / you're on a custom kernel with `+` in `uname -r`), the installer falls back to a local source build (~60–90s).

**Why you might want it.**

- **PipeWire dma-buf screen capture** — `xdg-desktop-portal-gnome` screencast, OBS Studio's PipeWire source, browser screen-share via PipeWire.
- **EGL device-platform consumers** — gstreamer's GL pipeline, ffmpeg's `egl` source, headless rendering test harnesses.
- **Wayland clients that probe DRI before flipping to Wayland mode** — some Electron apps (Slack, Discord, VS Code with `--ozone-platform=wayland`), nested Wayland compositors, some games.
- **Browsers' GPU sandboxing checks** — Firefox WebRender will at least *try* the hardware-decode codepath instead of disabling it outright.

**What it does NOT do.**

- **Not GPU acceleration.** VGEM is a virtual driver — apps using it still render via llvmpipe (CPU). It only unblocks codepaths that disable themselves when no render node exists.
- **Doesn't fix the chroma watermark in the RDP video stream.** That's a separate problem in `gnome-remote-desktop`'s EGL gate that the modules don't address; see the comment block in `lib/renderd_kernel.sh` for the three-layer analysis.
- **Doesn't help apps that already work via WSLg's relay** (those use Microsoft's own dma-buf path through `/mnt/wslg/`).

### Auto-update on kernel bump

When Microsoft pushes a new WSL kernel via the Microsoft Store, `uname -r` changes and the previously-installed modules' vermagic stops matching — `modprobe` rejects the load, `/dev/dri/renderD128` quietly disappears. Next time you run `wsl-rdp-gnome-renew`, the installer detects this (modules-load.d marker exists, but no .ko's for current `uname -r`) and silently re-fetches the prebuilt for the new kernel.

### Knobs

- `INSTALL_RENDERD=0` — uncheck the box pre-emptively; if previously installed, the installer cleanly removes the modules + persistence file.
- `INSTALL_RENDERD_FORCE=1` — force a re-fetch/rebuild even if everything looks current.
- `RENDERD_LOCAL_BUILD=1` — skip the prebuilt download, always build from source locally (useful when forking / inspecting).
- `RENDERD_PREBUILT_URL_BASE=…` — point at a different release host (self-hosting, fork mirror).
- `RENDERD_TAG=…` — override the kernel tag to fetch (default is derived from `uname -r`).

Verify any time with:

```bash
./extras/renderd/verify.sh
```

Prints PASS/FAIL for: .ko files present for current kernel, modules-load.d persistence, VGEM is the backing driver, `/dev/dri/renderD128` exists, user is in `video` + `render` groups.

---

## Optional: persist the distro across closing the shell

The component checklist defaults the **"Persist distro across closing the shell"** box to **OFF**. WSL2 terminates a distro session as soon as the last `wsl.exe` client exits — closing the PowerShell window you used to launch WSL takes `gnome-shell-headless` + `grd` down with it, dropping any active RDP connection. `vmIdleTimeout=-1` does *not* fix this: it governs the lightweight VM, not the per-distro session, so the kernel keeps running but the distro inside it is gone.

Opt in to drop a tiny `.vbs` into `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\` that launches a hidden `wsl.exe -d <distro> -- /usr/bin/sleep infinity` at every Windows logon. That hidden client holds the distro session open across any number of shell open/close cycles.

**Trade-off.** With the anchor running, WSL keeps eating its allocated memory until you explicitly `wsl --shutdown` — closing your shell no longer drops the distro, so it no longer triggers per-distro process cleanup. The reclaim path is exactly the same as before (`wsl --shutdown` returns RAM to Windows) but you have to invoke it deliberately. The anchor re-fires on next Windows logon.

**Knobs.**

- `INSTALL_ANCHOR=1` — pre-check the box (or check it in the menu).
- `INSTALL_ANCHOR=0` — default; if previously installed, the installer removes the `.vbs` on the next run.
- The anchor is per-distro (filename includes `$WSL_DISTRO_NAME`), so multi-distro setups can anchor each independently.

The `.vbs` is dropped at install time but only fires at the *next* Windows logon. To start the anchor immediately without logging out, double-click the file in Explorer once.

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
- Relies on the sibling [wsl-qol](https://codeberg.org/techneut92/wsl-qol) repo's `wslg-pulse-detach.service` (auto-installed by the bootstrap phase) to detach WSLg's pre-created `/run/user/$UID/pulse → /mnt/wslg/runtime-dir/pulse` symlink (mode `0700` UID 1000, hardcoded by Microsoft) so `pipewire-pulse.socket` can bind on a renumbered UID.

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
  qol_bootstrap.sh                             clone + run codeberg.org/techneut92/wsl-qol
  packages.sh                                  dnf/apt packages, flatpaks
  cgroup_collision.sh                          multi-distro detect + UID renumber
  dbus.sh                                      systemd 259 drop-in + user-bus bootstrap
  cert.sh                                      TLS cert generation
  configure.sh                                 grdctl + systemd user units
  pop_shell.sh                                 Pop Shell build + enable
  renderd_kernel.sh                            opt-in custom kernel for /dev/dri/renderD128
  anchor.sh                                    opt-in Windows Startup-folder VBS anchor for distro persistence
  verify.sh                                    end-of-run sanity check + summary
extras/
  renderd/
    verify.sh                                  post-`wsl --shutdown` checks for the custom kernel
units/
  gnome-shell-headless.service                 user unit
  gnome-remote-desktop-headless.override.conf  software-EGL override for grd
  wslg-x11-unix-fix.service                    /tmp/.X11-unix layout fix for self-spawned Xwayland
environment.d/
  10-wsl-gpu.conf                              GALLIUM_DRIVER for client apps (regenerated per host GPU)
  20-gnome-session.conf                        XDG_CURRENT_DESKTOP / SESSION_TYPE
  30-rdp-display.conf                          GDK_BACKEND=wayland (route to wayland-grd)
  40-cursor.conf                               XCURSOR_SIZE=24 for native Xwayland clients
```

## Tested on

| Distro              | WSL version | Notes                          |
| ------------------- | ----------- | ------------------------------ |
| Fedora Linux 44     | 2.7.3.0     | Primary development target.    |
| Ubuntu 26.04 LTS    | 2.7.3.0     | Secondary target. Several Ubuntu-specific quirks handled by the installer (see below); RDP session matches Fedora performance once the script lands. |

### Ubuntu-specific notes

The Ubuntu pipeline carries extra steps for things Fedora gets for free:

- **`wsl-renderd-modules`'s vgem/vkms loaded in the shared WSL kernel** puts `/dev/dri/card*` and `/dev/dri/renderD*` on the system with kernel-default GIDs (39, 108) — which on Ubuntu map to `irc` / `netdev` instead of `video` / `render`. A udev rule (`/etc/udev/rules.d/99-wsl-dri.rules`) pins the canonical group names so the `video`/`render` users that `wsl-qol` adds actually get device access; without it libEGL silently falls back to swrast.
- **WSLg shadows `/tmp/.X11-unix` as a read-only tmpfs** on 26.04+ rather than the symlink older WSLg used. The `wslg-x11-unix-fix.service` helper stacks a writable tmpfs over the path and re-symlinks WSLg's `X0` socket inside — without it Mutter's Xwayland refuses to start and gnome-shell-headless SIGABRTs in a loop.
- **`localsearch-3.service` guards itself with `ConditionEnvironment=XDG_SESSION_CLASS=user`**. PAM-less lingering sessions never plant that var, the service silently skips activation, and dbus then waits its full 120s `service_start_timeout` on every `Tracker3.Miner.Files` call — gnome-control-center's Search panel hits it on every open. The session env file in `environment.d/20-gnome-session.conf` sets the var explicitly.
- **`bluetooth.service`, `ModemManager.service`, and `fwupd.service`** are masked: their backing daemons hang for the full 25s `service_start_timeout` on dbus activation (Settings panels probe them on launch). On Fedora these same units fail-fast, no mask needed.
- **`mesa-vulkan-drivers`** is pulled in explicitly — Ubuntu's `gnome-core` doesn't pull it transitively the way Fedora's `gnome-shell` does.
- **`snapd`** is optional. By default Ubuntu pre-installs snapd plus ~1.5 GB of snaps you didn't pick, and on a headless RDP session the snap stack adds idle CPU, dbus traffic per udev event, and squashfs+cgroup setup cost per launch. The installer prompts during setup; opting in masks `snapd.service` and its sockets (snaps stay on disk, reversible with `systemctl unmask`). Desktop apps in this pipeline come from flatpak — snap interop isn't tuned here.

If you've run this on a different distro/WSL combination and it
worked (or didn't), open a PR/issue extending this table.

