# shellcheck shell=bash
# bivy tools: every tool bivy declares, the level that declares it, and what mise
# actually runs. The tools that only the user's own mise config sets come last.

# Prints "tool<TAB>requested<TAB>version<TAB>installed<TAB>config file" for what mise
# has active from HOME. mise gives physical paths, so a HOME reached through a
# symlink, such as /var on macOS, is put back as HOME.
tools_active() {
  local rows real
  # shellcheck disable=SC2016 # A yq expression, not shell.
  rows=$(mise_run ls --current --json 2>/dev/null |
    "$BIVY_YQ" -p json -o tsv \
      'to_entries | .[] | .key as $tool | .value[] | [$tool, .requested_version, .version, (.installed | tostring), .source.path]') ||
    return 1
  real=$(cd -P "$HOME" && pwd) || real=$HOME
  [ "$real" != "$HOME" ] || {
    printf '%s\n' "$rows"
    return 0
  }
  # Literal replacement: bash 3.2 mangles a ${var//pattern/text} holding slashes.
  printf '%s\n' "$rows" | awk -v real="$real/" -v home="$HOME/" '{
    out = ""; rest = $0
    while ((i = index(rest, real)) > 0) {
      out = out substr(rest, 1, i - 1) home
      rest = substr(rest, i + length(real))
    }
    print out rest
  }'
}

# The versions mise runs for one declared tool, in the declared order. Another
# config file than bivy's wins over it, and says so.
tools_state() {
  local name=$1 versions=$2 active=$3 rows source version found out=""
  rows=$(printf '%s\n' "$active" | awk -F'\t' -v t="$name" '$1 == t')
  if [ -z "$rows" ]; then
    printf 'not applied; run: bivy apply'
    return 0
  fi
  source=$(printf '%s\n' "$rows" | awk -F'\t' -v c="$BIVY_MISE_CONF" '$5 != c { print $5; exit }')
  if [ -n "$source" ]; then
    printf '%s, set by %s' \
      "$(printf '%s\n' "$rows" | awk -F'\t' -v s="$source" '$5 == s { print $3 }' | tools_short_list)" \
      "$(tilde_path "$source")"
    return 0
  fi
  for version in $versions; do
    found=$(printf '%s\n' "$rows" | awk -F'\t' -v v="$version" '$2 == v { print $3 "\t" $4; exit }')
    case "$found" in
      '') out="$out${out:+, }$version not applied; run: bivy apply" ;;
      *$'\t'true) out="$out${out:+, }$(short_version "${found%%$'\t'*}")" ;;
      *) out="$out${out:+, }$(short_version "${found%%$'\t'*}") not installed; run: bivy apply" ;;
    esac
  done
  printf '%s' "$out"
}

tools_short_list() {
  local version out=""
  while IFS= read -r version; do
    [ -n "$version" ] || continue
    out="$out${out:+, }$(short_version "$version")"
  done
  printf '%s' "$out"
}

# Aligns tab-separated columns; the last one is left as it is.
tools_table() {
  awk -F'\t' '
    { rows = NR; nf[NR] = NF
      for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
    END {
      for (r = 1; r <= rows; r++) {
        line = ""
        for (i = 1; i < nf[r]; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i])
        print line cell[r, nf[r]]
      }
    }'
}

cmd_tools() {
  local merged active name versions level resolved source
  [ $# -eq 0 ] || die "tools takes no argument"

  bivy_init_paths
  bivy_load_os
  mise_find >/dev/null || die "mise is not installed; run the bivy bootstrap first"
  yq_resolve || die "$BIVY_YQ_TOOL is not installed; run: bivy init"
  config_load
  if (profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH") 2>/dev/null; then
    profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  else
    warn "the profile is not cloned yet; run: bivy apply"
  fi

  merged=$(tools_merged)
  active=$(tools_active) || active=""
  {
    printf 'TOOL\tDECLARED\tFROM\tACTIVE\n'
    while IFS=$'\t' read -r name versions level; do
      [ -n "$name" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$name" "$(printf '%s' "$versions" | sed 's/ /, /g')" "$level" \
        "$(tools_state "$name" "$versions" "$active")"
    done <<<"$merged"
    # Set by the user's own mise config only.
    # BSD awk takes no newline in a -v value, so the names are joined with spaces.
    printf '%s\n' "$active" | awk -F'\t' -v declared="$(printf '%s\n' "$merged" | cut -f1 | tr '\n' ' ')" '
      BEGIN { split(declared, d, " "); for (i in d) known[d[i]] = 1 }
      NF == 5 && !($1 in known) {
        if (!($1 in req)) order[++n] = $1
        req[$1] = req[$1] (req[$1] == "" ? "" : ", ") $2
        ver[$1] = ver[$1] (ver[$1] == "" ? "" : " ") $3
        src[$1] = $5
      }
      END { for (i = 1; i <= n; i++) print order[i] "\t" req[order[i]] "\t" ver[order[i]] "\t" src[order[i]] }' |
      while IFS=$'\t' read -r name versions resolved source; do
        printf '%s\t%s\tmise\t%s, set by %s\n' "$name" "$versions" \
          "$(printf '%s\n' "$resolved" | tr ' ' '\n' | tools_short_list)" "$(tilde_path "$source")"
      done
  } | tools_table
  printf '\nbivy apply merges the bivy, profile and machine levels into %s.\n' "$(tilde_path "$BIVY_MISE_CONF")"
}
