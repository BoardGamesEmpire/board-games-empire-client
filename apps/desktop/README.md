# desktop

Board Games Empire desktop application

## Building on Linux

Besides Flutter's own Linux packages, the build links WebKitGTK and libsoup.
`flutter_web_auth_2`, which signs in through a provider on macOS, brings in
`desktop_webview_window` on every desktop platform, and its Linux plugin
needs them even though the app never opens a webview there (#583).

On Ubuntu or Debian:

```shell
sudo apt-get install libwebkit2gtk-4.1-dev libsoup-3.0-dev
```

On Fedora:

```shell
sudo dnf install webkit2gtk4.1-devel libsoup3-devel
```

A machine that runs the app needs the runtime libraries, `libwebkit2gtk-4.1-0`
and `libsoup-3.0-0` (Fedora: `webkit2gtk4.1` and `libsoup3`).

Windows needs nothing extra to build: the plugin carries the WebView2 headers
and loader itself.

## Linux: opening bge:// links

The bundle carries a desktop entry, an icon and two scripts. From the bundle
directory, register the app for the current user:

```shell
./install-desktop.sh
```

This writes the entry and the icon under `~/.local/share` (or
`$XDG_DATA_HOME`) and makes the app the default handler for `bge://` links.
The entry holds the bundle's absolute path, so run the script again after you
move the bundle. Running it twice is safe; it overwrites.

To check it, run:

```shell
xdg-open 'bge://settings'
```

If the app is already running, a second `xdg-open` reaches that instance
instead of starting another.

When the bundle's path contains a space or another special character, some
systems' `xdg-open` can't start the app from a link (xdg-utils 1.1.3 when no
desktop environment is detected). Extract the bundle to a path without one and
run `./install-desktop.sh` again.

`./uninstall-desktop.sh` removes the entry, the icon and the `bge://` default.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
