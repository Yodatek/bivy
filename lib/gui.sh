# shellcheck shell=bash
# Puts the mise shims on the PATH of graphical apps, which read no startup file
# when started from the Dock, a launcher or a file manager. Each OS adapter provides:
#   os_gui_file             the generated file
#   os_gui_render <out>     writes its content; fails if a path cannot be written safely
#   os_gui_activate <0|1>   applies it to the running session; 1 when the file changed
#   os_gui_session_state    0 when the running session has the shims, 1 when it
#                           does not, 2 when it cannot tell

# The PATH that env.sh gives a process starting with the given PATH.
gui_path_from() {
  # shellcheck disable=SC2016 # Expanded by the child shell.
  env -i HOME="$HOME" PATH="$1" /bin/sh -c '. "$1" && printf "%s" "$PATH"' povy-gui "$POVY_ENV_SH"
}

gui_apply() {
  local tmp before
  tmp=$(mktemp "$POVY_STATE_DIR/gui.XXXXXX") || die "cannot write in $POVY_STATE_DIR"
  if ! os_gui_render "$tmp"; then
    rm -f "$tmp"
    warn "graphical apps: $POVY_SHIMS_DIR cannot be written safely in $(os_gui_file); add it to their PATH yourself"
    return 0
  fi
  before=$POVY_WRITTEN
  install_file "$tmp" "$(os_gui_file)" 644
  rm -f "$tmp"
  if [ "$POVY_WRITTEN" -ne "$before" ]; then
    os_gui_activate 1
  else
    os_gui_activate 0
  fi
}
