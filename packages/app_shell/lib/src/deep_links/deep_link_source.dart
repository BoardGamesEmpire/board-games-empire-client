/// Platform seam for receiving out-of-band deep links (#10).
///
/// "Out-of-band" means links delivered by the operating system outside the
/// normal navigation flow: `bge://` custom-scheme URLs on Android and
/// macOS. Web has no such channel — the browser URL *is* the link and
/// `go_router` reads it directly from the address bar — so
/// `PlatformBootstrap.createDeepLinkSource` returns null there.
///
/// The native implementation (`AppLinksDeepLinkSource` in
/// `native_platform`) adapts the `app_links` plugin; this contract keeps
/// that dependency out of the web-safe shell, mirroring how
/// `PlatformBootstrap` keeps `dart:io`/`dart:ffi` concretes out.
abstract interface class DeepLinkSource {
  /// Every URI delivered to this app instance, in delivery order.
  ///
  /// Includes the **launch link** (the URI that cold-started the app, if
  /// any) followed by links arriving while the app is running. Emitted
  /// URIs are raw and unvalidated — `bge://` or otherwise — and must go
  /// through [normalizeDeepLink] before any routing decision. Never log
  /// an emitted URI directly; use [redactDeepLinkForLog].
  Stream<Uri> get uris;
}
