import 'feedback_sink.dart';
import 'queued_feedback_report.dart';

/// RAM implementation of [FeedbackSink] (#69, #97).
///
/// Two jobs: the **web stand-in** until #63 gives web a durable store
/// (an approved-but-unsent report survives within the session and is
/// lost on reload — the prompt tells the user so), and `runBgeApp`'s
/// resolve-or-default fallback when a platform module registered no
/// sink. Nothing about a RAM sink is platform-specific, so it lives in
/// `observability`.
///
/// Insertion order is preserved so [pending] drains oldest-first.
///
/// [pending] has no reject path, so the discard obligation in the
/// [FeedbackSink] contract is satisfied trivially: [persist] refuses an
/// un-addressable record up front, records are keyed by the value read
/// off the record itself (so key and address cannot disagree), and
/// nothing here can decay into an undecodable state the way persisted
/// bytes can.
class MemoryFeedbackSink implements FeedbackSink {
  final Map<String, QueuedFeedbackReport> _byKey = {};
  final List<String> _order = [];

  @override
  Future<void> persist(QueuedFeedbackReport record) async {
    final key = record.storageKey;
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        record.storageKey,
        'record.report.clientRequestId',
        'MemoryFeedbackSink requires a storage key',
      );
    }
    if (!_byKey.containsKey(key)) _order.add(key);
    _byKey[key] = record;
  }

  @override
  Future<List<QueuedFeedbackReport>> pending() async => [
    for (final key in _order) _byKey[key]!,
  ];

  @override
  Future<void> remove(String storageKey) async {
    if (_byKey.remove(storageKey) != null) {
      _order.remove(storageKey);
    }
  }
}
