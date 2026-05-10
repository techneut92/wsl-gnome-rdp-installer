# lib/qol_bootstrap.sh — vendor in github.com/techneut92/wsl-qol.
#
# wsl-qol owns the desktop-agnostic WSL2 fixes (WSLInterop binfmt,
# flatpak Start-Menu auto-publish, theme sync, WSLg pulse-detach,
# flatpak base setup). This RDP installer needs all of those to be
# in place before the rest of its pipeline runs:
#
#   - Flatpak Firefox + ONLYOFFICE installs (later in install_packages)
#     trip the .path unit qol installs; without that, no Start-Menu sync.
#   - The flatpak --nofilesystem=/tmp override has to be active before
#     ONLYOFFICE is installed or the first launch crashes.
#   - WSLInterop drop-in needs to land before any reg.exe call (theme
#     detection, etc.) or those silently no-op.
#
# Clone or refresh the sibling repo into ~/.local/share/wsl-qol, then
# `exec` its install.sh with our env so it inherits NONINTERACTIVE,
# QOL_*=0/1, etc. wsl-qol is opt-out per-fix so a power user can
# disable specific tiers via the QOL_* vars.
#
# Branch selection (regression-testing): set WSL_QOL_BRANCH to clone or
# pull a non-default branch. On this regression-test branch of the
# installer the default is `regression-test/no-features` (an
# all-features-OFF wsl-qol) so the bootstrap mechanism is exercised
# without any wsl-qol behaviors firing.

bootstrap_wsl_qol() {
  ui_phase "WSL QOL (sibling project)"
  local dir="${WSL_QOL_DIR:-$HOME/.local/share/wsl-qol}"
  local url="${WSL_QOL_URL:-https://github.com/techneut92/wsl-qol.git}"
  local branch="${WSL_QOL_BRANCH:-regression-test/no-features}"

  if [ -d "$dir/.git" ]; then
    ui_spin "Fetch $dir" \
      git -C "$dir" fetch origin "$branch"
    ui_spin "Checkout $branch" \
      git -C "$dir" checkout -B "$branch" "origin/$branch"
  else
    install -d "$(dirname "$dir")"
    ui_spin "Clone wsl-qol ($branch) → $dir" \
      git clone --depth=20 --branch "$branch" "$url" "$dir"
  fi
  ui_detail "→ $(git -C "$dir" log -1 --format='%h %s')"

  # Run the sibling installer from within this same shell so its
  # ui_step output and FLATPAKS_NEWLY_LINKED export flow back into
  # our verify summary's restart hint.
  WSL_QOL_PROJECT_ROOT="$dir" bash "$dir/install.sh"
}
