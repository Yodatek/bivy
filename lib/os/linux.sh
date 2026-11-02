# shellcheck shell=bash
# Linux adapter: GNU or BusyBox userland.

os_file_mode() { stat -c '%a' "$1"; }

os_bash_login_default() { echo .profile; }

os_preflight() { :; }

os_doctor() { :; }
