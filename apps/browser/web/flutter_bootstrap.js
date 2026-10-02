// Flutter's default bootstrap, without its service worker (#418).
//
// The default passes the loader a service-worker version that flutter_tools
// picks at random on every build, so no two builds of one commit produced
// the same flutter_bootstrap.js. The worker itself is deprecated, and on the
// pinned Flutter it only unregisters itself, so leaving it out loses nothing.
//
// This file is a template: flutter_tools fills in names written in double
// braces wherever they appear, comments included. Naming the service-worker
// one here, even in a comment, would bring the random value back.
{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load();
