#!/bin/sh
# Removes what install-desktop.sh wrote for the current user (#84).
set -eu

app_id=com.boardgamesempire.app

data_home=${XDG_DATA_HOME:-$HOME/.local/share}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
apps_dir=$data_home/applications
icon_root=$data_home/icons/hicolor

rm -f "$apps_dir/$app_id.desktop" "$icon_root/256x256/apps/$app_id.png"
echo "Removed the entry and the icon"

if command -v update-desktop-database >/dev/null 2>&1 && [ -d "$apps_dir" ]; then
  # Best effort, so a failed refresh can't leave the bge default behind.
  update-desktop-database "$apps_dir" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -d "$icon_root" ]; then
  gtk-update-icon-cache -f -t "$icon_root" || true
fi

mimeapps=$config_home/mimeapps.list
line="x-scheme-handler/bge=$app_id.desktop"
if [ -f "$mimeapps" ] && { grep -qxF "$line" "$mimeapps" || grep -qxF "$line;" "$mimeapps"; }; then
  tmp=$mimeapps.tmp.$$
  # grep exits 1 when no line is left, which is fine; 2 or more is an error,
  # and the user's file must stay as it is.
  status=0
  grep -vxF -e "$line" -e "$line;" "$mimeapps" >"$tmp" || status=$?
  if [ "$status" -ge 2 ]; then
    rm -f "$tmp"
    echo "Could not edit $mimeapps; left it as it was" >&2
    exit 1
  fi
  # Write in place so a symlinked file stays a symlink and keeps its mode.
  cat "$tmp" >"$mimeapps"
  rm -f "$tmp"
  echo "Removed the bge:// default from $mimeapps"
fi
