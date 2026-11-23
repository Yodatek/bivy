# shellcheck shell=bash
# System packages, for what mise does not install: brew formulas and casks on macOS,
# apt on Debian, Ubuntu and WSL2, dnf on Fedora and RHEL, and winget on Windows, which
# the PowerShell engine handles. Each list is used where its manager exists, only
# missing packages are installed, and nothing is ever removed.

POVY_PACKAGE_MANAGERS="brew cask apt dnf winget"
POVY_PACKAGE_RE='^[A-Za-z0-9][A-Za-z0-9._+@/-]*$'

# Prints "manager<TAB>name" lines for a [packages] table.
toml_packages() {
  local file=$1 tag manager names name
  tag=$(toml_query "$file" '(.packages // {}) | tag') || die "$file is not valid TOML"
  [ "$tag" = '!!map' ] || die "$file: packages must be a table: [packages]"
  for manager in $(toml_query "$file" '(.packages // {}) | keys | .[]'); do
    case " $POVY_PACKAGE_MANAGERS " in
      *" $manager "*) ;;
      *) die "$file: unknown package manager: $manager (use $POVY_PACKAGE_MANAGERS)" ;;
    esac
    tag=$(toml_query "$file" ".packages.$manager | tag")
    [ "$tag" = '!!seq' ] || die "$file: packages.$manager must be a list"
    tag=$(toml_query "$file" "[.packages.${manager}[] | tag | select(. != \"!!str\")] | length")
    [ "$tag" = 0 ] || die "$file: packages.$manager must be a list of names"
    names=$(toml_query "$file" ".packages.${manager}[]")
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [[ "$name" =~ $POVY_PACKAGE_RE ]] || die "$file: invalid package name for $manager: $name"
      printf '%s\t%s\n' "$manager" "$name"
    done <<<"$names"
  done
}

# The command that runs a manager here, or nothing when it is missing.
packages_command() {
  case "$1" in
    brew | cask) command -v brew 2>/dev/null ;;
    apt) command -v apt-get 2>/dev/null ;;
    dnf) command -v dnf 2>/dev/null ;;
    winget) ;;
  esac
}

# apt and dnf need root. Without a terminal to type a password, sudo must not wait.
packages_sudo() {
  if [ "$(id -u)" = 0 ]; then
    return 0
  elif ! command -v sudo >/dev/null 2>&1; then
    return 1
  elif tty_available; then
    printf 'sudo\n'
  else
    printf 'sudo\n-n\n'
  fi
}

# Prints the names among the arguments that the manager has not installed.
packages_missing_for() {
  local manager=$1 installed name
  shift
  case "$manager" in
    brew) installed=$(brew list --formula -1 2>/dev/null) ;;
    cask) installed=$(brew list --cask -1 2>/dev/null) ;;
  esac
  for name in "$@"; do
    case "$manager" in
      brew | cask) printf '%s\n' "$installed" | grep -qxF "${name##*/}" && continue ;;
      apt) dpkg-query -W -f='${db:Status-Abbrev}' "$name" 2>/dev/null | grep -q '^ii' && continue ;;
      dnf) rpm -q "$name" >/dev/null 2>&1 && continue ;;
    esac
    printf '%s\n' "$name"
  done
}

# Prints "manager<TAB>name" for every wanted package that is missing here, and
# "none<TAB>name" for those whose managers are all absent.
packages_missing() {
  local wanted=$1 manager names usable=0
  local -a list
  [ -n "$wanted" ] || return 0
  for manager in $POVY_PACKAGE_MANAGERS; do
    names=$(printf '%s\n' "$wanted" | awk -F'\t' -v m="$manager" '$1 == m { print $2 }')
    [ -n "$names" ] || continue
    [ -n "$(packages_command "$manager")" ] || continue
    usable=1
    IFS=$'\n' read -r -d '' -a list <<<"$names" || true
    packages_missing_for "$manager" "${list[@]}" | awk -v m="$manager" '{ print m "\t" $0 }'
  done
  if [ "$usable" -eq 0 ]; then
    printf '%s\n' "$wanted" | awk -F'\t' '{ print "none\t" $2 }' | sort -u
  fi
}

packages_install() {
  local manager=$1 sudo_line
  local -a sudo=() cmd
  shift
  case "$manager" in
    brew) cmd=(brew install "$@") ;;
    cask) cmd=(brew install --cask "$@") ;;
    apt | dnf)
      sudo_line=$(packages_sudo) || return 1
      [ -z "$sudo_line" ] || IFS=$'\n' read -r -d '' -a sudo <<<"$sudo_line" || true
      if [ "$manager" = apt ]; then
        ${sudo[@]+"${sudo[@]}"} apt-get update -qq >&2 || true
        cmd=(${sudo[@]+"${sudo[@]}"} apt-get install -y "$@")
      else
        cmd=(${sudo[@]+"${sudo[@]}"} dnf install -y "$@")
      fi
      ;;
  esac
  "${cmd[@]}" >&2 </dev/null
}

# The packages of the profile and of the machine, without duplicates.
packages_wanted() {
  printf '%s\n%s\n' "${PROFILE_PACKAGES:-}" "${CFG_PACKAGES:-}" | awk 'NF' | sort -u
}

packages_apply() {
  local missing manager names
  local -a list
  missing=$(packages_missing "$(packages_wanted)")
  [ -n "$missing" ] || return 0
  names=$(printf '%s\n' "$missing" | awk -F'\t' '$1 == "none" { print $2 }' | tr '\n' ' ')
  [ -z "$names" ] || warn "no package manager here for: $names(use $POVY_PACKAGE_MANAGERS)"
  for manager in $POVY_PACKAGE_MANAGERS; do
    names=$(printf '%s\n' "$missing" | awk -F'\t' -v m="$manager" '$1 == m { print $2 }')
    [ -n "$names" ] || continue
    IFS=$'\n' read -r -d '' -a list <<<"$names" || true
    info "installing with $manager: ${list[*]}"
    packages_install "$manager" "${list[@]}" ||
      warn "could not install with $manager: ${list[*]}; install them yourself, then run: povy doctor"
  done
}
