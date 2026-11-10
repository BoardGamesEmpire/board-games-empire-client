import 'dart:js_interop';

import 'package:observability/observability.dart' show BgeLogger;
import 'package:web/web.dart' as web;
import 'package:web_network/web_network.dart'
    show
        WebProviderSignInBindings,
        providerSignInMarkerKey,
        readProviderSignInReturn;

/// The browser half of a provider sign-in (#583), captured by
/// `bgeWebPlatformBootstrap` and handed to the repository through
/// `buildWebServerScope`.
///
/// Here rather than in `web_network`, which compiles for every target and so
/// cannot name `package:web`. Same split, and the same reason, as
/// `webSessionBindings` beside it.
///
/// Reads what this page load brought back from a provider, synchronously, so
/// that `main()` runs it before the router can rewrite the address:
///
/// 1. Reads the return id the marker holds, set by a provider sign-in before
///    it left the page, and removes the marker whatever the load, so that no
///    later load can read it again.
/// 2. Reads the address with it ([readProviderSignInReturn]). The load is the
///    attempt's return only when the address carries the same return id, as
///    the server's redirect back does. Back from the provider page, a reload
///    of the page that left, and an address the user reaches by hand in the
///    same tab after giving up on the provider, a typed address or a
///    bookmark, all keep the marker but not the id. Taken as a return with no
///    `?error=`, any of these would read as a success: its first session
///    read would announce a sign-in to the other tabs over whatever cookie
///    the jar holds, and a tab whose sign-out failed to revoke it would then
///    adopt that cookie. Not a return, an `?error=` is not this tab's to
///    report, and stays where it is.
///
///    How the page was loaded is not asked (#583). Only the return itself
///    carries the id, so a reload of it, or a Back and Forward to it, before
///    this first ran is still that return, and is read as one.
/// 3. Takes the return id, and with a return `error` and
///    `error_description`, out of the address bar with
///    `history.replaceState`, so a reload does not read the return again,
///    and a copied address does not carry it to another tab.
///
/// It also listens for the page being shown again. A page the back-forward
/// cache restores runs no `main()`, so it would stay on the attempt it left
/// from, with the marker set. One restored with the marker is reloaded with
/// the marker gone, and starts at rest.
///
/// Call it once per page load: a second call finds the marker gone and reads
/// no return.
///
/// The bindings' page navigator sets the marker to the attempt's return id,
/// then navigates the page to the provider. A browser that refuses session
/// storage refuses the marker too, so the navigator throws and the page
/// stays: its return would be read as no return at all, and a refusal would
/// go unexplained.
///
/// Nothing here logs the address, which carries the provider's own `state` on
/// the way out and its error on the way back.
///
/// [listenForPageShow] and [reload] stand in for the browser's, for tests:
/// the runner's page is never restored from the cache, and reloading it would
/// end the run.
WebProviderSignInBindings captureWebProviderSignIn({
  void Function(void Function({required bool persisted}) onPageShow)
      listenForPageShow =
      _listenForPageShow,
  void Function() reload = _reload,
}) {
  listenForPageShow(
    ({required persisted}) =>
        _settleCacheRestore(persisted: persisted, reload: reload),
  );

  final read = readProviderSignInReturn(
    marker: _takeMarker(),
    address: Uri.base,
  );

  final cleaned = read.cleanedAddress;
  if (cleaned != null) {
    try {
      web.window.history.replaceState(null, '', cleaned.toString());
    } on Object catch (error) {
      // The marker is already gone, so a reload ignores the `?error=` left
      // behind. Not worth failing `main()` over.
      _log.warn(
        'Could not take a provider sign-in error out of the address',
        context: {'cause': error.runtimeType.toString()},
      );
    }
  }

  return WebProviderSignInBindings(
    leavePageFor: _leavePageFor,
    startupReturn: read.startupReturn,
  );
}

/// The return id the marker holds, or null when it is not set, removing it
/// either way.
///
/// Null where the browser refuses session storage, which it does by throwing
/// on access when site data is blocked. No sign-in could have set a marker
/// there, and `main()` must not fail over it.
String? _takeMarker() {
  try {
    final storage = web.window.sessionStorage;
    final returnId = storage.getItem(providerSignInMarkerKey);
    storage.removeItem(providerSignInMarkerKey);
    return returnId;
  } on Object catch (error) {
    _log.warn(
      'Session storage is unavailable; this page load is not read as a '
      'provider sign-in return',
      context: {'cause': error.runtimeType.toString()},
    );
    return null;
  }
}

/// Calls [onPageShow] on every `pageshow`, with whether the back-forward
/// cache restored the page.
void _listenForPageShow(
  void Function({required bool persisted}) onPageShow,
) {
  web.window.addEventListener(
    'pageshow',
    ((web.PageTransitionEvent event) => onPageShow(
      persisted: event.persisted,
    )).toJS,
  );
}

/// Reloads a page the back-forward cache restored after it left for a
/// provider, removing the marker first.
///
/// The reload is a load of type `reload` with no marker, so it starts as any
/// other: no banner, and live buttons. Never throws: it runs in a browser
/// event listener, with no caller to hear it.
void _settleCacheRestore({
  required bool persisted,
  required void Function() reload,
}) {
  if (!persisted) return;
  try {
    final storage = web.window.sessionStorage;
    if (storage.getItem(providerSignInMarkerKey) == null) return;
    storage.removeItem(providerSignInMarkerKey);
    _log.info('Reloading a page restored after it left for a sign-in provider');
    reload();
  } on Object catch (error) {
    _log.warn(
      'Could not reload a page restored after it left for a sign-in '
      'provider',
      context: {'cause': error.runtimeType.toString()},
    );
  }
}

void _reload() => web.window.location.reload();

/// Sets the marker to [returnId], then navigates the page to [url].
///
/// The marker goes first: a page that leaves without it comes back to an
/// address that is not read as a return.
void _leavePageFor(Uri url, String returnId) {
  web.window.sessionStorage.setItem(providerSignInMarkerKey, returnId);
  web.window.location.assign(url.toString());
}

/// Named for the layer, matching `bge.platform.web_storage`.
final _log = BgeLogger('bge.platform.web.provider_sign_in');
