# lib/ui.sh — pretty terminal output: colors, headers, and an inline
# spinner for long commands. Sourced once from install.sh — early
# enough that even cgroup-collision precheck can use it. Every helper
# degrades to plain text when stdout isn't a TTY (logs/CI/file
# redirection), so output stays grep-friendly.

# --- color escapes --------------------------------------------------
# Detect TTY once. NO_COLOR (https://no-color.org) opts out regardless
# of TTY status, matching what most CLIs do.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_BLUE=$'\033[34m'
    UI_MAGENTA=$'\033[35m'
    UI_CYAN=$'\033[36m'
    UI_DIM=$'\033[2m'
    UI_BOLD=$'\033[1m'
    UI_RESET=$'\033[0m'
    UI_TTY=1
else
    UI_RED=""; UI_GREEN=""; UI_YELLOW=""; UI_BLUE=""
    UI_MAGENTA=""; UI_CYAN=""; UI_DIM=""; UI_BOLD=""; UI_RESET=""
    UI_TTY=0
fi

# --- headers --------------------------------------------------------
# Three levels:
#   ui_phase     bold-cyan ━━━ rule banner. Top-level orchestrator
#                stages ("Preflight", "Host setup", "RDP services").
#   ui_step      bold-magenta name. Each install_X / configure_X step.
#   ui_subhead   bold-cyan name + colon. Subsections within a step.
ui_phase()   { printf '\n%s━━━ %s ━━━%s\n' "$UI_BOLD$UI_CYAN"    "$1" "$UI_RESET"; }
ui_step()    { printf '\n%s%s%s\n'         "$UI_BOLD$UI_MAGENTA" "$1" "$UI_RESET"; }
ui_subhead() { printf '%s%s:%s\n'          "$UI_BOLD$UI_CYAN"    "$1" "$UI_RESET"; }

# --- result lines --------------------------------------------------
# Two-level indent convention:
#   ui_ok / ui_warn / ui_err / ui_skip — 2-space indent, the
#       "primary action" with its colored status icon.
#   ui_detail — 4-space indent, dim text. Sub-info under the action
#       above (e.g. "✓ Generate TLS cert" / "    via openssl").
#   ui_info — same as ui_detail in look, kept as an alias for legacy
#       call sites that still emit standalone dim status lines.
ui_ok()     { printf '  %s✓%s %s\n'  "$UI_GREEN"  "$UI_RESET" "$1"; }
ui_warn()   { printf '  %s⚠%s %s\n'  "$UI_YELLOW" "$UI_RESET" "$1"; }
ui_err()    { printf '  %s✗%s %s\n'  "$UI_RED"    "$UI_RESET" "$1" >&2; }
ui_skip()   { printf '  %s∼%s %s\n'  "$UI_DIM"    "$UI_RESET" "$1"; }
ui_detail() { printf '    %s%s%s\n'  "$UI_DIM"    "$1" "$UI_RESET"; }
ui_info()   { printf '    %s%s%s\n'  "$UI_DIM"    "$1" "$UI_RESET"; }

# --- inline spinner -------------------------------------------------
# `ui_spin "label" cmd args...` — same in-place pattern npm/pnpm/yarn
# use. Prints "⠋ <label>" on the current line, redraws the spinner
# char in place every 100ms via \r (carriage return), then on
# completion overwrites that line with "✓ <label>" or "✗ <label>"
# plus a newline so subsequent output continues fresh.
#
# Captures cmd's stdout+stderr to a temp file; on failure dumps the
# last 20 lines indented under the ✗ for diagnosability.
#
# Non-TTY (logs/CI): no \r magic; just runs cmd silently and emits
# the final result line. Output stays grep-friendly.
_UI_SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

ui_spin() {
    local label="$1"; shift
    local rc=0

    if [ "$UI_TTY" != "1" ]; then
        "$@" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then ui_ok "$label"; else ui_err "$label"; fi
        return $rc
    fi

    local out
    out=$(mktemp)
    "$@" >"$out" 2>&1 &
    local pid=$!

    # Repaint the spinner line every tick. \r returns the cursor to
    # column 1; the new char + label overwrites the old frame in
    # place. \033[K clears any leftover characters at end of line in
    # case the previous label was longer.
    local i=0 char
    while kill -0 "$pid" 2>/dev/null; do
        char="${_UI_SPIN_CHARS:$i:1}"
        printf '\r  %s%s%s %s\033[K' "$UI_BOLD$UI_BLUE" "$char" "$UI_RESET" "$label"
        i=$(( (i + 1) % ${#_UI_SPIN_CHARS} ))
        sleep 0.1
    done
    wait "$pid" || rc=$?

    # Replace the spinner line with the final result.
    if [ "$rc" -eq 0 ]; then
        printf '\r  %s✓%s %s\033[K\n' "$UI_GREEN" "$UI_RESET" "$label"
    else
        printf '\r  %s✗%s %s\033[K\n' "$UI_RED" "$UI_RESET" "$label"
        tail -20 "$out" 2>/dev/null | sed 's/^/    /' >&2
    fi
    rm -f "$out"
    return $rc
}
