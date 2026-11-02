# shellcheck shell=bash
# macOS adapter: BSD userland.

os_file_mode() { stat -f '%Lp' "$1"; }

os_bash_login_default() { echo .bash_profile; }

os_preflight() { :; }

os_doctor() { :; }
