import 'dart:async';

import 'package:observability/observability.dart';

import 'deep_link_normalizer.dart';
import 'deep_link_redaction.dart';
import 'deep_link_source.dart';
import 'pending_deep_link_holder.dart';

/// Receives raw deep links, normalizes them, and stores the latest valid
/// one in the [PendingDeepLinkHolder] (#10).
///
/// This is deliberately the whole of #10's live pipeline: **receive →
/// normalize → hold**. Draining the holder (routing, server switching,
/// auth gating) is #82/#83 scope. Rejected links are logged at warning
/// level — redacted via [redactDeepLinkForLog], never raw — and dropped.
///
/// Lifecycle mirrors `AppBootstrapCubit`: constructed and [start]ed once
/// per boot by `runBgeApp` (native only — web's source is null and no
/// handler is created), disposed by the owning widget
/// (`BgeApp.disposeDeepLinkHandlerOnDispose`).
class DeepLinkHandler {
  DeepLinkHandler({
    required DeepLinkSource source,
    required PendingDeepLinkHolder holder,
    BgeLogger? logger,
  }) : _source = source,
       _holder = holder,
       _logger = logger ?? BgeLogger('bge.shell.deep_links');

  final DeepLinkSource _source;
  final PendingDeepLinkHolder _holder;
  final BgeLogger _logger;

  bool _started = false;
  StreamSubscription<Uri>? _subscription;

  /// Subscribes to the source. Call exactly once; a second call is a
  /// programmer error and throws [StateError] (the `initialize()`
  /// precedent from `AppBootstrapCubit`).
  ///
  /// Source stream errors are logged and survived — a transport hiccup
  /// must not kill deep-link reception for the rest of the session
  /// (`cancelOnError` stays false).
  void start() {
    if (_started) {
      throw StateError(
        'DeepLinkHandler.start() may only be called once per instance',
      );
    }
    _started = true;
    _subscription = _source.uris.listen(_onUri, onError: _onSourceError);
  }

  void _onUri(Uri uri) {
    // Redacted once, up front — the raw URI never reaches a log line.
    final redacted = redactDeepLinkForLog(uri);
    switch (normalizeDeepLink(uri)) {
      case DeepLinkNormalized(:final link):
        _holder.set(link);
        _logger.info('Deep link received and held: $redacted');
      case DeepLinkRejected(:final reason):
        _logger.warn('Deep link rejected (${reason.name}): $redacted');
    }
  }

  void _onSourceError(Object error, StackTrace stackTrace) {
    _logger.warn(
      'Deep-link source stream error; continuing to listen',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Cancels the subscription. Links emitted after disposal are ignored.
  /// Safe to call without [start] and safe to call repeatedly.
  Future<void> dispose() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}
