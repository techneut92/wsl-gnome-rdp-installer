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

# --- interactive prompts (inquirer / clack / gum style) -------------
#
# All three render in-place using ANSI escapes — no dialog overlay,
# no full-screen takeover. After confirmation the multi-line prompt
# collapses into a one-line dim summary so the transcript stays clean.
#
#   ui_input "Label" "default"      → echoes the value typed (or default)
#   ui_password "Label"             → echoes the value typed (no confirm)
#   ui_multiselect "Title" item ... → multi-select checklist; echoes
#                                     selected tags, one per line.
#                                     Each item is "tag|description|ON|OFF".
#
# All three require a TTY on stdin/stdout — die otherwise. The terminal
# state (echo, icanon, cursor visibility) is restored via traps even
# when the user kills the process mid-prompt.

# Dim "?" prefix in cyan, matching clack/inquirer.
_ui_q='?'
_ui_chk_on='◉'
_ui_chk_off='◯'

# Self-contained die for prompt helpers — install.sh's normal flow
# loads lib/common.sh which redefines this with full ui_err styling,
# but the prompt helpers also need to abort gracefully when ui.sh
# is sourced standalone (smoke tests, manual debugging).
_ui_die() { printf '%s✗%s %s\n' "$UI_RED" "$UI_RESET" "$*" >&2; exit 1; }

# UI output goes to /dev/tty so it stays visible when the caller captures
# the function's stdout via $( ). The actual return value (the typed
# string / selected tags) goes to stdout, where $( ) expects it.
# Reading is from fd 0 directly — `read -p` would write the prompt to
# stderr (which $( ) doesn't capture, but stderr isn't always the TTY
# either), so we write the prompt explicitly to /dev/tty first.

ui_input() {
  local label="$1" default="${2:-}"
  if [ "$UI_TTY" != "1" ] || ! [ -t 0 ]; then
    _ui_die "ui_input: not a TTY"
  fi
  local prompt
  if [ -n "$default" ]; then
    prompt=$(printf '%s%s%s %s%s%s %s(%s)%s ' \
      "$UI_BOLD$UI_CYAN" "$_ui_q" "$UI_RESET" \
      "$UI_BOLD" "$label" "$UI_RESET" \
      "$UI_DIM" "$default" "$UI_RESET")
  else
    prompt=$(printf '%s%s%s %s%s%s ' \
      "$UI_BOLD$UI_CYAN" "$_ui_q" "$UI_RESET" \
      "$UI_BOLD" "$label" "$UI_RESET")
  fi
  local input
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r input </dev/tty
  input="${input:-$default}"
  # Collapse the multi-part prompt into a single dim summary line.
  # \r returns the cursor to column 1 in case `read` left it past the
  # prompt+input on a wrapped line; \033[1A then moves up to that line;
  # \033[2K clears it; printf overwrites with the summary.
  printf '\r\033[1A\033[2K  %s✓%s %s%s%s\n' \
    "$UI_GREEN" "$UI_RESET" "$UI_DIM" "$label: $input" "$UI_RESET" >/dev/tty
  printf '%s' "$input"
}

ui_password() {
  local label="$1"
  if [ "$UI_TTY" != "1" ] || ! [ -t 0 ]; then
    _ui_die "ui_password: not a TTY"
  fi
  local prompt
  prompt=$(printf '%s%s%s %s%s%s ' \
    "$UI_BOLD$UI_CYAN" "$_ui_q" "$UI_RESET" \
    "$UI_BOLD" "$label" "$UI_RESET")
  local input
  printf '%s' "$prompt" >/dev/tty
  IFS= read -rs input </dev/tty
  printf '\n' >/dev/tty
  # Collapse into a single ✓ line; never show the password content.
  printf '\r\033[1A\033[2K  %s✓%s %s%s%s\n' \
    "$UI_GREEN" "$UI_RESET" "$UI_DIM" "$label: ********" "$UI_RESET" >/dev/tty
  printf '%s' "$input"
}

# Multi-select. Args after $1 (title): one or more "tag|description|state"
# strings, where state is ON or OFF (initial check). Echoes selected tags
# to stdout, one per line. Returns 1 on cancel (Esc / q / Ctrl+C).
#
# Renders inline at the cursor position. On each keypress the menu region
# is overwritten in place via \033[<n>A (move up) + \033[J (clear to end
# of screen). On confirm, the menu collapses to a one-line ✓ summary.
ui_multiselect() {
  if [ "$UI_TTY" != "1" ] || ! [ -t 0 ]; then
    _ui_die "ui_multiselect: not a TTY"
  fi

  # Open fd 3 to the controlling terminal so the menu rendering and
  # final summary stay visible even when the caller captures stdout
  # via $( ). Selected tags are emitted on stdout (fd 1) at the end —
  # those are what $( ) is meant to collect.
  exec 3>/dev/tty

  local title="$1"; shift

  local -a tags descs states
  local i raw
  for raw in "$@"; do
    tags+=("${raw%%|*}");        raw="${raw#*|}"
    descs+=("${raw%%|*}");       raw="${raw#*|}"
    states+=("$raw")
  done
  local n=${#tags[@]}
  if [ "$n" -eq 0 ]; then
    exec 3>&-
    return 1
  fi

  # Save terminal state so traps can restore it.
  local _saved_stty
  _saved_stty=$(stty -g 2>/dev/null) || _saved_stty=""
  _ui_multiselect_restore() {
    [ -n "$_saved_stty" ] && stty "$_saved_stty" 2>/dev/null
    printf '\033[?25h' >&3 2>/dev/null
    exec 3>&- 2>/dev/null
  }
  trap _ui_multiselect_restore EXIT INT TERM
  stty -echo -icanon 2>/dev/null
  printf '\033[?25l' >&3   # hide cursor

  local cursor=0
  local hint_lines=2   # title + (↑↓ space enter) hint
  local total_lines=$(( hint_lines + n ))
  local first_render=1

  # Render block — every printf goes to fd 3 (the terminal), never
  # to stdout, so $( ) capture sees no UI noise.
  _ui_multiselect_render() {
    local i checkbox desc
    if [ "$first_render" = "0" ]; then
      printf '\033[%dA\033[J' "$total_lines" >&3
    fi
    first_render=0
    printf '%s%s%s%s\n' "$UI_BOLD$UI_CYAN" "$_ui_q" "$UI_RESET" " $UI_BOLD$title$UI_RESET" >&3
    printf '  %s↑↓ navigate · space toggle · enter confirm · q/esc cancel%s\n' \
      "$UI_DIM" "$UI_RESET" >&3
    for ((i=0; i<n; i++)); do
      desc="${descs[i]}"
      if [ "${states[i]}" = "ON" ]; then
        checkbox="$UI_GREEN$_ui_chk_on$UI_RESET"
      else
        checkbox="$UI_DIM$_ui_chk_off$UI_RESET"
      fi
      if [ "$i" = "$cursor" ]; then
        printf '  %s❯%s %s %s%s%s\n' \
          "$UI_CYAN" "$UI_RESET" "$checkbox" "$UI_BOLD" "$desc" "$UI_RESET" >&3
      else
        printf '    %s %s\n' "$checkbox" "$desc" >&3
      fi
    done
  }

  local key key2
  while :; do
    _ui_multiselect_render

    # Read one keystroke from the terminal directly (not stdin —
    # so this also works when the caller has stdin redirected).
    IFS= read -rsn1 key </dev/tty
    case "$key" in
      $'\033')
        # Escape sequence — could be bare ESC or arrow.
        IFS= read -rsn2 -t 0.05 key2 </dev/tty || key2=""
        case "$key2" in
          '[A'|'OA') cursor=$(( (cursor - 1 + n) % n )) ;;   # up
          '[B'|'OB') cursor=$(( (cursor + 1) % n )) ;;        # down
          '')        _ui_multiselect_restore; trap - EXIT INT TERM
                     return 1 ;;
        esac
        ;;
      ' ')
        if [ "${states[cursor]}" = "ON" ]; then
          states[cursor]=OFF
        else
          states[cursor]=ON
        fi
        ;;
      ''|$'\n'|$'\r')
        break
        ;;
      'q'|'Q'|$'\003')
        _ui_multiselect_restore; trap - EXIT INT TERM
        return 1
        ;;
      'a'|'A')
        # toggle-all helper (clack convention)
        local any_off=0
        for ((i=0; i<n; i++)); do
          [ "${states[i]}" = "OFF" ] && any_off=1
        done
        for ((i=0; i<n; i++)); do
          if [ "$any_off" = "1" ]; then states[i]=ON; else states[i]=OFF; fi
        done
        ;;
    esac
  done

  # Collapse the menu to a multi-line ✓ summary: title line, then one
  # bullet per chosen item showing the human-readable description (the
  # tag is the machine-readable shorthand emitted on stdout). Empty
  # selection collapses to a single "(none)" line.
  printf '\033[%dA\033[J' "$total_lines" >&3
  local -a chosen_descs=()
  for ((i=0; i<n; i++)); do
    [ "${states[i]}" = "ON" ] && chosen_descs+=("${descs[i]}")
  done
  if [ ${#chosen_descs[@]} -eq 0 ]; then
    printf '  %s✓%s %s%s: (none)%s\n' \
      "$UI_GREEN" "$UI_RESET" "$UI_DIM" "$title" "$UI_RESET" >&3
  else
    printf '  %s✓%s %s%s:%s\n' \
      "$UI_GREEN" "$UI_RESET" "$UI_DIM" "$title" "$UI_RESET" >&3
    local d
    for d in "${chosen_descs[@]}"; do
      printf '    %s• %s%s\n' "$UI_DIM" "$d" "$UI_RESET" >&3
    done
  fi

  _ui_multiselect_restore
  trap - EXIT INT TERM

  # Output selected tags on stdout for the caller's $( ) capture.
  # Explicit `return 0` because if the last item is OFF, the loop's
  # exit code is the failing `[` test from the && short-circuit, and
  # ui_multiselect would falsely report cancelled to the caller.
  for ((i=0; i<n; i++)); do
    [ "${states[i]}" = "ON" ] && printf '%s\n' "${tags[i]}"
  done
  return 0
}

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
