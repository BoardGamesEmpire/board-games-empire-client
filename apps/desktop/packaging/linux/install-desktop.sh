#!/bin/sh
# Registers this bundle as the handler for bge:// links for the current user
# (#84). Re-run it after moving the bundle: the entry names the bundle's
# absolute path.
set -eu

app_id=com.boardgamesempire.app
bundle=$(cd "$(dirname "$0")" && pwd)

case $bundle in
  *'
'*)
    echo "install-desktop.sh: the bundle path contains a newline: $bundle" >&2
    exit 1
    ;;
esac

data_home=${XDG_DATA_HOME:-$HOME/.local/share}
apps_dir=$data_home/applications
icon_root=$data_home/icons/hicolor
icon_dir=$icon_root/256x256/apps
entry=$apps_dir/$app_id.desktop

# Exec: the path is written bare unless it holds a character the Desktop Entry
# spec reserves (space, tab, newline, " ' \ > < ~ | & ; $ * ? # ( ) and the
# backtick). A bare path works in every launcher, including xdg-open's generic
# mode, which keeps the quotes of a quoted one and then cannot find the
# program. Only a path that needs it is quoted: ", `, $ and \ get a backslash,
# and as the value is a key-file string each backslash is doubled again, so
# \ -> \\\\, " -> \\", ` -> \\`, $ -> \\$. A literal % is %% either way.
needs_quote=0
case $bundle in
  *[\ \	\"\'\\\>\<\~\|\&\;\$\*\?\#\(\)\`]*) needs_quote=1 ;;
esac

if [ "$needs_quote" = 1 ]; then
  # shellcheck disable=SC2016 # the backtick and $ in these sed patterns are literal
  escaped=$(printf '%s' "$bundle" | sed \
    -e 's/\\/\\\\\\\\/g' \
    -e 's/"/\\\\"/g' \
    -e 's/`/\\\\`/g' \
    -e 's/\$/\\\\$/g' \
    -e 's/%/%%/g')
  exec_path="\"$escaped/board_games_empire\""
else
  exec_path="$(printf '%s' "$bundle" | sed -e 's/%/%%/g')/board_games_empire"
fi

# GLib (2.80) checks that the program named first in Exec exists before it
# expands %%, so it rejects a program path that holds one and gio-based
# launchers never offer the entry. With env as the program, the bundle path
# is an argument and is expanded first. xdg-utils 1.1.3's generic mode never
# expands %% at all, so a path with % fails there whatever the form.
case $bundle in
  *%*) exec_path="env $exec_path" ;;
esac

mkdir -p "$apps_dir" "$icon_dir"

tmp=$entry.tmp.$$
while IFS= read -r line || [ -n "$line" ]; do
  case $line in
    Exec=*) printf 'Exec=%s %%u\n' "$exec_path" ;;
    *) printf '%s\n' "$line" ;;
  esac
done <"$bundle/share/applications/$app_id.desktop" >"$tmp"
mv "$tmp" "$entry"
echo "Wrote $entry"

cp "$bundle/share/icons/hicolor/256x256/apps/$app_id.png" "$icon_dir/$app_id.png"
echo "Wrote $icon_dir/$app_id.png"

missing=
override=
if command -v update-desktop-database >/dev/null 2>&1; then
  # The refreshes are best effort: one that fails must not stop the bge
  # default from being set, so each reports and the script goes on.
  if update-desktop-database "$apps_dir"; then
    echo "Ran update-desktop-database"
  else
    echo "update-desktop-database failed; continuing" >&2
  fi
else
  missing="$missing update-desktop-database"
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default "$app_id.desktop" x-scheme-handler/bge
  # xdg-mime writes mimeapps.list, but a desktop's own list (such as
  # gnome-mimeapps.list) outranks it, so ask which handler is in effect. An
  # empty answer means xdg-mime can't tell; only a different app is an
  # override.
  effective=$(xdg-mime query default x-scheme-handler/bge 2>/dev/null) ||
    effective=
  if [ -n "$effective" ] && [ "$effective" != "$app_id.desktop" ]; then
    override=$effective
  else
    echo "Set $app_id.desktop as the default for bge://"
  fi
else
  missing="$missing xdg-mime"
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  if gtk-update-icon-cache -f -t "$icon_root"; then
    echo "Ran gtk-update-icon-cache"
  else
    echo "gtk-update-icon-cache failed; continuing" >&2
  fi
else
  missing="$missing gtk-update-icon-cache"
fi

if [ -n "$missing" ]; then
  echo "Not found, so skipped:$missing"
  echo "bge:// links may not open the app until the desktop refreshes its caches."
fi

if [ -n "$override" ]; then
  config_home=${XDG_CONFIG_HOME:-$HOME/.config}
  echo "bge:// links still open $override: a desktop-specific list such as" \
    "$config_home/gnome-mimeapps.list names it, and it outranks the default" \
    "this script set. Remove its x-scheme-handler/bge line, or pick Board" \
    "Games Empire in your desktop's default-apps settings, then run" \
    "./install-desktop.sh again." >&2
  exit 1
fi
