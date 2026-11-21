# shellcheck shell=bash
# povy banner: what is installed, what does not work right now and how loaded the
# machine is. It runs in every new terminal, so it only makes cheap checks: no yq,
# no network, no shell started. povy doctor makes the thorough ones.
#
# The full layout needs a UTF-8 terminal at least 80 columns wide; otherwise, or
# when the output is not a terminal, the banner fits on a few lines.
#
# With --auto, as the shell startup files call it, it stays quiet where a banner
# gets in the way. It exits 0 whatever it finds: a banner must not break a shell.

BANNER_PROBLEMS=0
BANNER_FULL=0
BANNER_HEALTH_SHOWN=0
BANNER_WIDTH=75
B_BOLD="" B_DIM="" B_OK="" B_WARN="" B_FAIL="" B_OFF=""
B_FG="" B_FRAME="" B_TREE="" B_HOST="" B_SYSTEM="" B_TOOLS="" B_HEALTH=""
B_ICON="*" B_SEP="-" B_MARK_OK="ok" B_MARK_WARN="!" B_MARK_FAIL="x"
B_LOGO_COLORS=""
B_CPU="" B_RAM="" B_DISK="" B_DISK_FULL=0
B_TOOL_LIST="" B_MISSING="" B_NO_MISE=0

# The word POVY in six rows, padded to the widest when drawn.
BANNER_LOGO='██████╗  ██████╗ ██╗   ██╗██╗   ██╗
██╔══██╗██╔═══██╗██║   ██║╚██╗ ██╔╝
██████╔╝██║   ██║██║   ██║ ╚████╔╝
██╔═══╝ ██║   ██║╚██╗ ██╔╝  ╚██╔╝
██║     ╚██████╔╝ ╚████╔╝    ██║
╚═╝      ╚═════╝   ╚═══╝     ╚═╝'

# IDE terminals, agents and dumb terminals get no banner, unless POVY_BANNER=1.
banner_quiet() {
  case "${POVY_BANNER:-}" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  [ "${TERM:-}" != dumb ] || return 0
  [ -z "${CLAUDECODE:-}${INSIDE_EMACS:-}" ] || return 0
  case "${TERM_PROGRAM:-}" in
    vscode | zed) return 0 ;;
  esac
  case "${TERMINAL_EMULATOR:-}" in
    JetBrains*) return 0 ;;
  esac
  return 1
}

# A Tokyo Night colour: true colour when the terminal says it has it, else the
# nearest of the 256.
banner_rgb() {
  case "${COLORTERM:-}" in
    truecolor | 24bit) printf '\033[38;2;%d;%d;%dm' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}" ;;
    *) printf '\033[38;5;%sm' "$2" ;;
  esac
}

# Colours in a terminal, or with CLICOLOR_FORCE=1; never with NO_COLOR.
banner_style() {
  local color=0 utf8=0 columns
  if [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ "${CLICOLOR_FORCE:-0}" != 0 ]; }; then
    color=1
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) utf8=1 ;;
  esac
  if [ "$color" -eq 1 ]; then
    B_BOLD=$'\033[1m' B_DIM=$'\033[2m' B_OFF=$'\033[0m'
    B_OK=$(banner_rgb 9ece6a 149) B_WARN=$(banner_rgb e0af68 179) B_FAIL=$(banner_rgb f7768e 210)
    B_FG=$(banner_rgb c0caf5 189) B_FRAME=$(banner_rgb 7aa2f7 111) B_TREE=$(banner_rgb 565f89 60)
    B_HOST=$(banner_rgb 73daca 79) B_SYSTEM=$(banner_rgb 7dcfff 117) B_TOOLS=$(banner_rgb bb9af7 141)
    B_HEALTH=$B_WARN
    B_LOGO_COLORS="$(banner_rgb bb9af7 141) $(banner_rgb a8a5f7 141) $(banner_rgb 94aef7 147)"
    B_LOGO_COLORS="$B_LOGO_COLORS $(banner_rgb 7aa2f7 111) $(banner_rgb 7cbbfb 111) $(banner_rgb 7dcfff 117)"
  fi
  if [ "$utf8" -eq 1 ]; then
    B_ICON="⛺" B_SEP="·" B_MARK_OK="✓" B_MARK_WARN="!" B_MARK_FAIL="✗"
  fi
  if [ -t 1 ]; then
    columns=$(tput cols 2>/dev/null) || columns=0
  else
    columns=${COLUMNS:-0}
  fi
  case "$columns" in
    '' | *[!0-9]*) columns=0 ;;
  esac
  if [ "$utf8" -eq 1 ] && [ "$columns" -ge 80 ]; then
    BANNER_FULL=1
  fi
}

banner_problem() {
  local color=$1 mark=$2 text=$3
  BANNER_PROBLEMS=$((BANNER_PROBLEMS + 1))
  if [ "$BANNER_FULL" -eq 0 ]; then
    printf '   %s%s %s%s\n' "$color" "$mark" "$text" "$B_OFF"
    return 0
  fi
  if [ "$BANNER_HEALTH_SHOWN" -eq 0 ]; then
    BANNER_HEALTH_SHOWN=1
    printf '  %s├─%s %s%shealth%s\n' "$B_TREE" "$B_OFF" "$B_BOLD" "$B_HEALTH" "$B_OFF"
  fi
  printf '  %s│%s  %s%s %s%s\n' "$B_TREE" "$B_OFF" "$color" "$mark" "$text" "$B_OFF"
}

banner_fail() { banner_problem "$B_FAIL" "$B_MARK_FAIL" "$*"; }

banner_warn() { banner_problem "$B_WARN" "$B_MARK_WARN" "$*"; }

# Values of one kind from the file apply leaves for the banner.
banner_applied() {
  [ -f "$POVY_APPLIED" ] || return 0
  awk -F'\t' -v kind="$1" '$1 == kind { print $2 }' "$POVY_APPLIED"
}

banner_profile() {
  local profile
  profile=$(banner_applied profile)
  profile=${profile%/}
  profile=${profile%.git}
  printf '%s' "${profile##*[/:]}"
}

# Sets B_CPU to "percent", B_RAM and B_DISK to "percent used total", the sizes in
# GB. The CPU is the one-minute load average over the number of cores, at most
# 100%: the load counts the processes waiting for a core too. No awk variable may
# be named load, which gawk reserves.
banner_collect_metrics() {
  local load mem disk values
  load=$(os_cpu_load 2>/dev/null) || load=""
  mem=$(os_memory 2>/dev/null) || mem=""
  disk=$(df -kP "$HOME" 2>/dev/null | awk 'NR == 2 { print $3 * 1024, $2 * 1024 }') || disk=""
  values=$(LC_ALL=C awk -v cpu="$load" -v mem="$mem" -v disk="$disk" '
    function size(bytes) { return sprintf(bytes >= 10 * 2^30 ? "%.0f" : "%.1f", bytes / 2^30) }
    function usage(pair,    v) {
      if (split(pair, v, " ") != 2 || v[2] <= 0) return ""
      return int(v[1] * 100 / v[2] + 0.5) " " size(v[1]) " " size(v[2])
    }
    BEGIN {
      c = ""
      if (split(cpu, l, " ") == 2 && l[2] > 0) {
        c = int(l[1] * 100 / l[2] + 0.5)
        if (c > 100) c = 100
      }
      print c "|" usage(mem) "|" usage(disk)
    }')
  IFS='|' read -r B_CPU B_RAM B_DISK <<<"$values"
  [ "${B_DISK%% *}" = "" ] || [ "${B_DISK%% *}" -lt 90 ] || B_DISK_FULL=1
}

# One mise call gives both the tools and, on stderr, those not installed. Versions of
# mise word that warning differently, so any tool@version that a warning about a
# missing tool names is kept. yq is left out: povy declares it for itself. Sets
# B_TOOL_LIST to "name<TAB>first version<TAB>other versions" lines.
banner_collect_tools() {
  local out line name versions version word first others
  if ! mise_find >/dev/null; then
    B_NO_MISE=1
    return 0
  fi
  # mise colours its output in some CI runners even through a pipe.
  out=$(NO_COLOR=1 mise_run current 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || out=""
  while IFS= read -r line; do
    case "$line" in
      "mise "*"missing"* | "mise "*"not installed"*)
        for word in $line; do
          word=${word%[,:;.]}
          case "$word" in
            ?*@?*) B_MISSING="$B_MISSING $word" ;;
          esac
        done
        continue
        ;;
      "mise "* | "") continue ;;
    esac
    name=${line%% *}
    versions=${line#* }
    [ "$name" != yq ] || continue
    first="" others=""
    for version in $versions; do
      version=$(short_version "$version")
      if [ -z "$first" ]; then
        first=$version
      else
        others="$others${others:+ }$version"
      fi
    done
    B_TOOL_LIST="$B_TOOL_LIST$name"$'\t'"$first"$'\t'"$others"$'\n'
  done <<<"$out"
}

# --- Compact layout ------------------------------------------------------------

# The colour of a percentage: none, then yellow from 75% and red from 90%.
banner_tint() {
  if [ "$1" -ge 90 ]; then
    printf '%s' "$B_FAIL"
  elif [ "$1" -ge 75 ]; then
    printf '%s' "$B_WARN"
  fi
}

banner_compact_metrics() {
  local parts="" pct used total
  if [ -n "$B_CPU" ]; then
    parts="$(banner_tint "$B_CPU")cpu $B_CPU%$B_OFF"
  fi
  if [ -n "$B_RAM" ]; then
    read -r pct used total <<<"$B_RAM"
    parts="$parts${parts:+ $B_SEP }$(banner_tint "$pct")ram $pct%$B_OFF $B_DIM$used/${total}G$B_OFF"
  fi
  if [ -n "$B_DISK" ]; then
    read -r pct used total <<<"$B_DISK"
    parts="$parts${parts:+ $B_SEP }$(banner_tint "$pct")disk $pct%$B_OFF $B_DIM$used/${total}G$B_OFF"
  fi
  [ -z "$parts" ] || printf '   %s\n' "$parts"
}

banner_compact() {
  local profile parts="" name first others
  profile=$(banner_profile)
  printf '%s%s povy%s %s %s@%s' "$B_BOLD" "$B_ICON" "$B_OFF" "$B_SEP" "${USER:-$(id -un)}" "${HOSTNAME%%.*}"
  [ -z "$profile" ] || printf ' %s profile %s' "$B_SEP" "$profile"
  printf ' %s %s\n' "$B_SEP" "$(date '+%a %d %b %H:%M')"
  banner_compact_metrics
  while IFS=$'\t' read -r name first others; do
    [ -n "$name" ] || continue
    others=${others// /, }
    parts="$parts${parts:+ $B_SEP }$name $first${others:+ (+$others)}"
  done <<<"$B_TOOL_LIST"
  [ -z "$parts" ] || printf '   %s%s%s\n' "$B_DIM" "$parts" "$B_OFF"
}

# --- Full layout ---------------------------------------------------------------

banner_repeat() {
  local text=$1 count=$2 out=""
  while [ "$count" -gt 0 ]; do
    out="$out$text"
    count=$((count - 1))
  done
  printf '%s' "$out"
}

# One framed row: the text, which is already coloured, centred on its visible width.
banner_row() {
  local text=$1 width=$2 left right
  left=$(((BANNER_WIDTH - width) / 2))
  right=$((BANNER_WIDTH - width - left))
  printf '  %s│%s%s%s%s%s│%s\n' "$B_FRAME" "$B_OFF" "$(banner_repeat ' ' "$left")" "$text" \
    "$(banner_repeat ' ' "$right")" "$B_FRAME" "$B_OFF"
}

banner_frame() {
  local line color user host profile date text width
  local -a colors
  read -r -a colors <<<"$B_LOGO_COLORS"
  user=${USER:-$(id -un)}
  host=${HOSTNAME%%.*}
  profile=$(banner_profile)
  date=$(date '+%A %d %B %H:%M')

  printf '  %s╭%s╮%s\n' "$B_FRAME" "$(banner_repeat '─' "$BANNER_WIDTH")" "$B_OFF"
  banner_row "" 0
  # Every row padded to the widest, so that the art stays aligned once centred.
  local i=0 logo_width=0
  while IFS= read -r line; do
    [ "${#line}" -le "$logo_width" ] || logo_width=${#line}
  done <<<"$BANNER_LOGO"
  while IFS= read -r line; do
    color=${colors[$i]:-}
    line="$line$(banner_repeat ' ' $((logo_width - ${#line})))"
    banner_row "$B_BOLD$color$line$B_OFF" "$logo_width"
    i=$((i + 1))
  done <<<"$BANNER_LOGO"
  banner_row "" 0
  # Long names must not push the frame: the profile goes first, then the host is cut.
  local room=$((BANNER_WIDTH - 4))
  [ $((${#user} + 1 + ${#host} + 3 + ${#profile})) -le "$room" ] || profile=""
  if [ $((${#user} + 1 + ${#host})) -gt "$room" ]; then
    host="${host:0:$((room - ${#user} - 2))}…"
  fi
  text="$B_BOLD$B_FG$user$B_OFF$B_HOST@$host$B_OFF"
  width=$((${#user} + 1 + ${#host}))
  if [ -n "$profile" ]; then
    text="$text $B_TREE$B_SEP$B_OFF $B_SYSTEM$profile$B_OFF"
    width=$((width + 3 + ${#profile}))
  fi
  banner_row "$text" "$width"
  banner_row "$B_TREE$date$B_OFF" "${#date}"
  banner_row "" 0
  printf '  %s╰%s╯%s\n' "$B_FRAME" "$(banner_repeat '─' "$BANNER_WIDTH")" "$B_OFF"
}

# A 20-cell gauge, green, then yellow from 75% and red from 90%.
banner_gauge() {
  local label=$1 pct=$2 detail=$3 filled color
  filled=$(((pct * 20 + 50) / 100))
  if [ "$pct" -ge 90 ]; then
    color=$B_FAIL
  elif [ "$pct" -ge 75 ]; then
    color=$B_WARN
  else
    color=$B_OK
  fi
  printf '  %s│%s  %s%-5s%s %s%s%s%s%s%s %s%s%3d%%%s  %s%s%s\n' "$B_TREE" "$B_OFF" \
    "$B_FG" "$label" "$B_OFF" "$color" "$(banner_repeat '█' "$filled")" "$B_OFF" \
    "$B_TREE" "$(banner_repeat '░' $((20 - filled)))" "$B_OFF" "$B_BOLD" "$color" "$pct" "$B_OFF" \
    "$B_DIM" "$detail" "$B_OFF"
}

banner_full_system() {
  local pct used total
  printf '  %s╭─%s %s%ssystem%s\n' "$B_TREE" "$B_OFF" "$B_BOLD" "$B_SYSTEM" "$B_OFF"
  [ -z "$B_CPU" ] || banner_gauge cpu "$B_CPU" ""
  if [ -n "$B_RAM" ]; then
    read -r pct used total <<<"$B_RAM"
    banner_gauge ram "$pct" "$used/${total}G"
  fi
  if [ -n "$B_DISK" ]; then
    read -r pct used total <<<"$B_DISK"
    banner_gauge disk "$pct" "$used/${total}G"
  fi
}

# Two tools per row when they fit in half the frame, one otherwise.
banner_full_tools() {
  local name first others width=0 cell plain line="" plain_line="" count=0
  local -a cells plains
  [ -n "$B_TOOL_LIST" ] || return 0
  while IFS=$'\t' read -r name first others; do
    [ -n "$name" ] || continue
    [ "${#name}" -le "$width" ] || width=${#name}
  done <<<"$B_TOOL_LIST"
  while IFS=$'\t' read -r name first others; do
    [ -n "$name" ] || continue
    others=${others:+ +${others// / +}}
    plain=$(printf "%-${width}s  %s%s" "$name" "$first" "$others")
    cell=$(printf "%s%-${width}s%s  %s%s%s%s%s%s" "$B_TOOLS" "$name" "$B_OFF" "$B_FG" "$first" "$B_OFF" \
      "$B_DIM" "$others" "$B_OFF")
    cells[count]=$cell
    plains[count]=$plain
    count=$((count + 1))
  done <<<"$B_TOOL_LIST"

  printf '  %s├─%s %s%stools%s\n' "$B_TREE" "$B_OFF" "$B_BOLD" "$B_TOOLS" "$B_OFF"
  local i=0 half=$(((BANNER_WIDTH - 4) / 2)) two=1
  for ((i = 0; i < count; i++)); do
    plain=${plains[i]}
    [ "${#plain}" -lt "$half" ] || two=0
  done
  i=0
  while [ "$i" -lt "$count" ]; do
    line=${cells[i]}
    plain_line=${plains[i]}
    if [ "$two" -eq 1 ] && [ $((i + 1)) -lt "$count" ]; then
      line="$line$(banner_repeat ' ' $((half - ${#plain_line} + 2)))${cells[i + 1]}"
      i=$((i + 2))
    else
      i=$((i + 1))
    fi
    printf '  %s│%s  %s\n' "$B_TREE" "$B_OFF" "$line"
  done
}

banner_full_end() {
  if [ "$BANNER_PROBLEMS" -eq 0 ]; then
    printf '  %s╰─%s %s%s all good%s  %spovy tools %s povy doctor%s\n' "$B_TREE" "$B_OFF" \
      "$B_BOLD$B_OK" "$B_MARK_OK" "$B_OFF" "$B_TREE" "$B_SEP" "$B_OFF"
  else
    printf '  %s╰─%s %spovy doctor tells more%s\n' "$B_TREE" "$B_OFF" "$B_DIM" "$B_OFF"
  fi
}

# --- Checks ------------------------------------------------------------------

banner_checks() {
  local secrets missing target path mode state overriding shadowed
  [ "$B_NO_MISE" -eq 0 ] || banner_fail "mise is not installed; run the povy bootstrap"
  [ -z "$B_MISSING" ] || banner_fail "not installed:$B_MISSING; run: povy apply"
  [ "$B_DISK_FULL" -eq 0 ] || banner_warn "the disk holding $(tilde_path "$HOME") is almost full"
  if [ ! -f "$POVY_APPLIED" ]; then
    banner_warn "povy apply has not run yet"
    return 0
  fi
  case ":$PATH:" in
    *":$POVY_SHIMS_DIR:"*) ;;
    *) banner_fail "the mise shims are not on the PATH of this shell; open a new terminal" ;;
  esac
  if mise_find >/dev/null; then
    shadowed=$(shims_shadowed "$PATH" "$(mise_active_commands)")
  else
    shadowed=""
  fi
  [ -z "$shadowed" ] || banner_warn "$(shims_shadowed_summary "$shadowed") before the mise shims"
  [ ! "$POVY_CONFIG_FILE" -nt "$POVY_APPLIED" ] ||
    banner_warn "config.toml changed since the last povy apply"
  [ ! "$POVY_ENV_FILE" -nt "$POVY_APPLIED" ] ||
    banner_warn ".env changed since the last povy apply"

  secrets=$(banner_applied secret)
  missing=$(env_missing "$secrets")
  [ -z "$missing" ] || banner_fail "empty secrets in $(tilde_path "$POVY_ENV_FILE"): $(printf '%s' "$missing" | tr '\n' ' ')"
  if [ -f "$POVY_ENV_FILE" ]; then
    mode=$(os_file_mode "$POVY_ENV_FILE") || mode=""
    [ "$mode" = 600 ] || banner_fail "$(tilde_path "$POVY_ENV_FILE") has mode $mode, expected 600"
  fi
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    path="$HOME/$target"
    if [ ! -f "$path" ]; then
      banner_fail "$(tilde_path "$path") is missing; run: povy apply"
      continue
    fi
    mode=$(os_file_mode "$path") || mode=""
    [ "$mode" = 600 ] || banner_fail "$(tilde_path "$path") has mode $mode, expected 600"
  done <<<"$(banner_applied file)"

  os_gui_session_state && state=0 || state=$?
  [ "$state" -ne 1 ] || banner_warn "graphical apps do not see the shims; log out and back in, or run: povy apply"

  if command -v git >/dev/null 2>&1; then
    overriding=$(git_overriding_files 2>/dev/null) || overriding=""
    [ -z "$overriding" ] ||
      banner_warn "user.name or user.email set after the povy include overrides it in: $(printf '%s' "$overriding" | tr '\n' ' ')"
  fi
}

cmd_banner() {
  local auto=0
  case "${1:-}" in
    --auto) auto=1 ;;
    '') ;;
    *) die "unknown option for banner: $1" ;;
  esac
  if [ "$auto" -eq 1 ] && banner_quiet; then
    return 0
  fi
  # A part that fails shows its error and the rest still prints.
  set +e +o pipefail

  povy_init_paths
  povy_load_os
  banner_style
  banner_collect_metrics
  banner_collect_tools
  if [ "$BANNER_FULL" -eq 1 ]; then
    banner_frame
    banner_full_system
    banner_full_tools
    banner_checks
    banner_full_end
    return 0
  fi
  banner_compact
  banner_checks
  if [ "$BANNER_PROBLEMS" -eq 0 ]; then
    printf '   %s%s all good%s\n' "$B_OK" "$B_MARK_OK" "$B_OFF"
  else
    printf '   %spovy doctor tells more%s\n' "$B_DIM" "$B_OFF"
  fi
}
