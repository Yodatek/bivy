# shellcheck shell=bash
# WSL2 adapter: Linux, plus the traps of sharing a machine with Windows.

# shellcheck source=lib/os/linux.sh
. "$POVY_ROOT/lib/os/linux.sh"

# chmod has no effect on a Windows drive by default, so secrets could not be
# protected there.
os_preflight() {
  case "$HOME" in
    /mnt/*) die "HOME is on a Windows drive ($HOME); use a home inside the Linux filesystem" ;;
  esac
}

# The Windows PATH is appended by default; a Windows mise cannot manage Linux tools.
os_doctor() {
  local bin
  bin=$(command -v mise 2>/dev/null) || return 0
  case "$bin" in
    /mnt/*) doctor_warn "mise resolves to a Windows binary: $bin" ;;
  esac
}
