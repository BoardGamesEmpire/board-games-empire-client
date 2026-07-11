import 'package:app_links/app_links.dart';
import 'package:app_shell/app_shell.dart';

/// Native [DeepLinkSource] backed by the `app_links` plugin (#10).
///
/// `app_links` is a native-only concern and therefore lives here in
/// `native_platform`, never in the web-safe `app_shell` — the same
/// platform-separation rule that put `connectivity_plus` in its own
/// platform package.
///
/// Plugin semantics this adapter relies on (app_links ^7.2.1):
/// - `AppLinks` is a singleton; instantiate it early (before bootstrap)
///   so the cold-start launch link is captured — `runBgeApp` calls
///   `PlatformBootstrap.createDeepLinkSource` before `initialize` for
///   exactly this reason;
/// - `uriLinkStream` emits the launch link (if any) to the first
///   subscriber and every subsequent link after it, which is precisely
///   the [DeepLinkSource.uris] contract — no separate initial-link fetch
///   or merge is needed.
class AppLinksDeepLinkSource implements DeepLinkSource {
  /// [uriLinkStream] is the injection seam for tests (the real plugin
  /// needs a platform channel); production callers pass nothing and get
  /// `AppLinks().uriLinkStream`.
  AppLinksDeepLinkSource({Stream<Uri>? uriLinkStream})
    : _injectedUriLinkStream = uriLinkStream;

  final Stream<Uri>? _injectedUriLinkStream;

  /// Memoized so [uris] is a stable stream per the [DeepLinkSource]
  /// contract: a fresh `AppLinks()`/stream per read would risk a second
  /// subscription if anything re-reads the getter. Lazy via `late` — the
  /// `AppLinks()` platform channel is touched only on first access (from
  /// `DeepLinkHandler.start`), never at mere construction, and never at
  /// all when a stream is injected in tests.
  late final Stream<Uri> _uris =
      _injectedUriLinkStream ?? AppLinks().uriLinkStream;

  @override
  Stream<Uri> get uris => _uris;
}
