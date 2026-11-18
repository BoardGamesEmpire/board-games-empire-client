import 'package:app_shell/src/deep_links/deep_link_normalizer.dart';
import 'package:flutter/foundation.dart';

/// Single-slot, latest-wins store for a deep link that cannot be acted on
/// yet (#10 decision: one slot, no queue, no TTL).
///
/// Links can arrive before the app is able to route them — before
/// bootstrap completes, or (for authenticated resources) before sign-in.
/// On native the `DeepLinkHandler` writes every successfully normalized
/// link here. Web has no link source: there the router's first redirect
/// writes the location the page was loaded at, so a reload or a bookmark
/// survives bootstrap and sign-in (#83). `BgeApp`'s `DeepLinkConsumer`
/// (#82) drains it on every platform, listening for each arrival: on native
/// through a server switch where the link needs one, on web straight to its
/// location. A held link is the most recent one received until the
/// consumer takes it.
///
/// Listeners are told when a link arrives ([set]), never when the slot
/// empties. The creator owns the holder's lifetime.
///
/// Not thread-safe and doesn't need to be: all access happens on the
/// platform event loop.
class PendingDeepLinkHolder extends ChangeNotifier {
  NormalizedDeepLink? _slot;

  /// The held link without consuming it, or null when the slot is empty.
  NormalizedDeepLink? get peek => _slot;

  /// Stores [link], replacing any previously held link (latest wins), and
  /// notifies listeners, even for a link equal to the held one: an equal
  /// link re-delivered must land again.
  void set(NormalizedDeepLink link) {
    _slot = link;
    notifyListeners();
  }

  /// Returns the held link and empties the slot, or null when empty.
  /// Consumption is single-shot: a taken link is gone.
  NormalizedDeepLink? take() {
    final link = _slot;
    _slot = null;
    return link;
  }

  /// Takes the held link only when it equals [expected]: empties the slot
  /// and returns it. Otherwise leaves the slot alone and returns null, so a
  /// newer link that replaced [expected] is not swallowed.
  NormalizedDeepLink? takeIf(NormalizedDeepLink expected) {
    if (_slot != expected) return null;
    return take();
  }

  /// Empties the slot without returning the link.
  void clear() => _slot = null;
}
