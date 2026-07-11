import 'deep_link_normalizer.dart';

/// Single-slot, latest-wins store for a deep link that cannot be acted on
/// yet (#10 decision: one slot, no queue, no TTL).
///
/// Links can arrive before the app is able to route them — before
/// bootstrap completes, or (for authenticated resources) before sign-in.
/// The `DeepLinkHandler` writes every successfully normalized link here;
/// draining is deliberately out of #10's scope: #82 consumes the slot for
/// server switching/affordances and #83 drains it after sign-in. Until
/// those land, a held link is simply the most recent one received.
///
/// Not thread-safe and doesn't need to be: all access happens on the
/// platform event loop.
class PendingDeepLinkHolder {
  NormalizedDeepLink? _slot;

  /// The held link without consuming it, or null when the slot is empty.
  NormalizedDeepLink? get peek => _slot;

  /// Stores [link], replacing any previously held link (latest wins).
  void set(NormalizedDeepLink link) => _slot = link;

  /// Returns the held link and empties the slot, or null when empty.
  /// Consumption is single-shot: a taken link is gone.
  NormalizedDeepLink? take() {
    final link = _slot;
    _slot = null;
    return link;
  }

  /// Empties the slot without returning the link.
  void clear() => _slot = null;
}
