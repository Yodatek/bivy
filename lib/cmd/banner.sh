# shellcheck shell=bash
# bivy banner: what is installed, what does not work right now and how loaded the
# machine is. It runs in every new terminal, so it only makes cheap checks: no yq,
# no network, no shell started. bivy doctor makes the thorough ones.
#
# With --auto, as the shell startup files call it, it stays quiet where a banner
# gets in the way. It exits 0 whatever it finds: a banner must not break a shell.

BANNER_PROBLEMS=0
B_BOLD="" B_DIM="" B_OK="" B_WARN="" B_FAIL="" B_OFF=""
B_ICON="*" B_SEP="-" B_MARK_OK="ok" B_MARK_WARN="!" B_MARK_FAIL="x"

# IDE terminals, agents and dumb terminals get no banner, unless BIVY_BANNER=1.
banner_quiet() {
  case "${BIVY_BANNER:-}" in
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

banner_style() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B_BOLD=$'\033[1m' B_DIM=$'\033[2m' B_OK=$'\033[32m' B_WARN=$'\033[33m'
    B_FAIL=$'\033[31m' B_OFF=$'\033[0m'
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
      B_ICON="⛺" B_SEP="·" B_MARK_OK="✓" B_MARK_WARN="!" B_MARK_FAIL="✗"
      ;;
  esac
}

banner_tilde() {
  # shellcheck disable=SC2088 # A path shown to a person, not expanded.
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

banner_fail() {
  printf '   %s%s %s%s\n' "$B_FAIL" "$B_MARK_FAIL" "$*" "$B_OFF"
  BANNER_PROBLEMS=$((BANNER_PROBLEMS + 1))
}

banner_warn() {
  printf '   %s%s %s%s\n' "$B_WARN" "$B_MARK_WARN" "$*" "$B_OFF"
  BANNER_PROBLEMS=$((BANNER_PROBLEMS + 1))
}

# Values of one kind from the file apply leaves for the banner.
banner_applied() {
  [ -f "$BIVY_APPLIED" ] || return 0
  awk -F'\t' -v kind="$1" '$1 == kind { print $2 }' "$BIVY_APPLIED"
}

# temurin-21.0.13+100000002.0.LTS -> 21.0.13, liberica-javafx-8u492+9 -> 8u492.
banner_short_version() {
  local version=$1
  if [[ "$version" =~ ^[A-Za-z][A-Za-z-]*-([0-9].*)$ ]]; then
    version=${BASH_REMATCH[1]}
  fi
  printf '%s' "${version%%+*}"
}

banner_header() {
  local profile
  profile=$(banner_applied profile)
  printf '%s%s bivy%s %s %s@%s' "$B_BOLD" "$B_ICON" "$B_OFF" "$B_SEP" "${USER:-$(id -un)}" "${HOSTNAME%%.*}"
  if [ -n "$profile" ]; then
    profile=${profile%/}
    profile=${profile%.git}
    printf ' %s profile %s' "$B_SEP" "${profile##*[/:]}"
  fi
  printf ' %s %s\n' "$B_SEP" "$(date '+%a %d %b %H:%M')"
}

# CPU is the one-minute load average over the number of cores, at most 100%: the load
# counts the processes waiting for a core too. No awk variable may be named load,
# which gawk reserves.
banner_metrics() {
  local load disk mem
  load=$(os_cpu_load 2>/dev/null) || load=""
  mem=$(os_memory 2>/dev/null) || mem=""
  disk=$(df -kP "$HOME" 2>/dev/null | awk 'NR == 2 { print $3 * 1024, $2 * 1024 }') || disk=""
  LC_ALL=C awk -v cpu="$load" -v mem="$mem" -v disk="$disk" -v sep="$B_SEP" \
    -v warn="$B_WARN" -v fail="$B_FAIL" -v dim="$B_DIM" -v off="$B_OFF" '
    function tint(pct) { return pct >= 90 ? fail : (pct >= 75 ? warn : "") }
    function size(bytes) { return sprintf(bytes >= 10 * 2^30 ? "%.0f" : "%.1f", bytes / 2^30) }
    function usage(label, pair,    v, pct) {
      if (split(pair, v, " ") != 2 || v[2] <= 0) return ""
      pct = int(v[1] * 100 / v[2] + 0.5)
      return sprintf("%s%s %d%%%s %s%s/%sG%s", tint(pct), label, pct, off, dim, size(v[1]), size(v[2]), off)
    }
    BEGIN {
      n = 0
      if (split(cpu, l, " ") == 2 && l[2] > 0) {
        pct = int(l[1] * 100 / l[2] + 0.5)
        if (pct > 100) pct = 100
        part[++n] = sprintf("%scpu %d%%%s", tint(pct), pct, off)
      }
      if ((s = usage("ram", mem)) != "") part[++n] = s
      if ((s = usage("disk", disk)) != "") part[++n] = s
      if (n == 0) exit
      line = "   " part[1]
      for (i = 2; i <= n; i++) line = line " " sep " " part[i]
      print line
    }'
  if [ -n "$disk" ] && awk -v d="$disk" 'BEGIN { split(d, v, " "); exit !(v[2] > 0 && v[1] * 100 / v[2] >= 90) }'; then
    banner_warn "the disk holding $(banner_tilde "$HOME") is almost full"
  fi
}

# One mise call gives both the tools and, on stderr, those not installed. Versions of
# mise word that warning differently, so any tool@version that a warning about a
# missing tool names is kept. yq is left out: bivy declares it for itself.
banner_tools() {
  local out line name versions version word first others parts="" missing=""
  if ! mise_find >/dev/null; then
    banner_fail "mise is not installed; run the bivy bootstrap"
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
            ?*@?*) missing="$missing $word" ;;
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
      version=$(banner_short_version "$version")
      if [ -z "$first" ]; then
        first=$version
      else
        others="$others${others:+, }$version"
      fi
    done
    parts="$parts${parts:+ $B_SEP }$name $first${others:+ (+$others)}"
  done <<<"$out"
  [ -z "$parts" ] || printf '   %s%s%s\n' "$B_DIM" "$parts" "$B_OFF"
  [ -z "$missing" ] || banner_fail "not installed:$missing; run: bivy apply"
}

banner_checks() {
  local secrets missing target path mode state overriding shadowed
  if [ ! -f "$BIVY_APPLIED" ]; then
    banner_warn "bivy apply has not run yet"
    return 0
  fi
  case ":$PATH:" in
    *":$BIVY_SHIMS_DIR:"*) ;;
    *) banner_fail "the mise shims are not on the PATH of this shell; open a new terminal" ;;
  esac
  if mise_find >/dev/null; then
    shadowed=$(shims_shadowed "$PATH" "$(mise_active_commands)")
  else
    shadowed=""
  fi
  [ -z "$shadowed" ] || banner_warn "$(shims_shadowed_summary "$shadowed") before the mise shims"
  [ ! "$BIVY_CONFIG_FILE" -nt "$BIVY_APPLIED" ] ||
    banner_warn "config.toml changed since the last bivy apply"
  [ ! "$BIVY_ENV_FILE" -nt "$BIVY_APPLIED" ] ||
    banner_warn ".env changed since the last bivy apply"

  secrets=$(banner_applied secret)
  missing=$(env_missing "$secrets")
  [ -z "$missing" ] || banner_fail "empty secrets in $(banner_tilde "$BIVY_ENV_FILE"): $(printf '%s' "$missing" | tr '\n' ' ')"
  if [ -f "$BIVY_ENV_FILE" ]; then
    mode=$(os_file_mode "$BIVY_ENV_FILE") || mode=""
    [ "$mode" = 600 ] || banner_fail "$(banner_tilde "$BIVY_ENV_FILE") has mode $mode, expected 600"
  fi
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    path="$HOME/$target"
    if [ ! -f "$path" ]; then
      banner_fail "$(banner_tilde "$path") is missing; run: bivy apply"
      continue
    fi
    mode=$(os_file_mode "$path") || mode=""
    [ "$mode" = 600 ] || banner_fail "$(banner_tilde "$path") has mode $mode, expected 600"
  done <<<"$(banner_applied file)"

  os_gui_session_state && state=0 || state=$?
  [ "$state" -ne 1 ] || banner_warn "graphical apps do not see the shims; log out and back in, or run: bivy apply"

  if command -v git >/dev/null 2>&1; then
    overriding=$(git_overriding_files 2>/dev/null) || overriding=""
    [ -z "$overriding" ] ||
      banner_warn "user.name or user.email set after the bivy include overrides it in: $(printf '%s' "$overriding" | tr '\n' ' ')"
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

  bivy_init_paths
  bivy_load_os
  banner_style
  banner_header
  banner_metrics
  banner_tools
  banner_checks
  if [ "$BANNER_PROBLEMS" -eq 0 ]; then
    printf '   %s%s all good%s\n' "$B_OK" "$B_MARK_OK" "$B_OFF"
  else
    printf '   %sbivy doctor tells more%s\n' "$B_DIM" "$B_OFF"
  fi
}
