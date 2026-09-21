import 'feedback_sink.dart';
import 'queued_feedback_report.dart';

/// RAM implementation of [FeedbackSink] (#69, #97).
///
/// The **fallback**, on every platform. `runBgeApp` resolves it when no
/// platform module registered a sink, and web's composition root registers it
/// when the browser refuses storage (#292). It stopped being web's standing
/// implementation when `IndexedDbFeedbackSink` landed.
///
/// An approved-but-unsent report held here survives within the session and is
/// lost on reload. The prompt does **not** say so — it promises a later send
/// on every platform, which is #385, not something this sink can fix.
///
/// Nothing about a RAM sink is platform-specific, so it lives in
/// `observability`.
///
/// Insertion order is preserved so [pending] drains oldest-first.
///
/// Bounded at [QueuedFeedbackReport.maxQueuedReports] (#359): a deployment
/// where nothing can ever drain — a proxy answering every POST with its own
/// 200 — would otherwise grow this map without limit for the life of the
/// session. See [_evictOverflow] for why eviction orders by `queuedAt` and
/// not by insertion.
///
/// [pending] has no reject path, so the discard obligation in the
/// [FeedbackSink] contract is satisfied trivially: [persist] and [update]
/// both refuse an un-addressable record up front, records are keyed by
/// the value read off the record itself (so key and address cannot
/// disagree), and nothing here can decay into an undecodable state the
/// way persisted bytes can.
class MemoryFeedbackSink implements FeedbackSink {
  final Map<String, QueuedFeedbackReport> _byKey = {};
  final List<String> _order = [];

  @override
  Future<void> persist(QueuedFeedbackReport record) async {
    final key = _requireKey(record);
    if (!_byKey.containsKey(key)) _order.add(key);
    _byKey[key] = record;
    _evictOverflow(justPersisted: key);
  }

  @override
  Future<void> update(QueuedFeedbackReport record) async {
    final key = _requireKey(record);
    // Absent = evicted or already drained (#376). Writing it back here is
    // the resurrection this method exists to make impossible.
    if (!_byKey.containsKey(key)) return;
    // [_order] is untouched: the key is already in it, in its arrival
    // position, and an update is not an arrival. No eviction pass either —
    // the map cannot have grown.
    _byKey[key] = record;
  }

  /// The record's address, or [ArgumentError] if it has none. Shared by
  /// [persist] and [update] so the two cannot come to disagree about what
  /// this sink will accept.
  String _requireKey(QueuedFeedbackReport record) {
    final key = record.storageKey;
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        record.storageKey,
        'record.report.clientRequestId',
        'MemoryFeedbackSink requires a storage key',
      );
    }
    return key;
  }

  /// Holds the queue at [QueuedFeedbackReport.maxQueuedReports], evicting
  /// oldest-first (#359).
  ///
  /// Ordered by [QueuedFeedbackReport.compareByAge] — the one age rule both
  /// sinks share — with insertion order as the tie-break, so equal stamps
  /// and the legacy records that all sort at
  /// [QueuedFeedbackReport.epoch] evict in the order they arrived.
  ///
  /// **Why a scan rather than `_order.first`.** For records this sink
  /// stamped itself the two agree, and neither write disturbs that:
  /// [persist] appends to [_order] only for a new key, and [update] never
  /// touches it, so the drain's retry bump leaves arrival order alone.
  /// What the scan buys is the case [_order] cannot see: `queuedAt`
  /// arrives on the record, so a caller may supply any value, and a device
  /// clock that steps backwards makes a freshly stamped record genuinely
  /// older than stored ones. Sorting by the stamp keeps this sink and
  /// `FileFeedbackSink` — where a rewrite *does* restamp the file —
  /// agreeing about what "oldest" means.
  ///
  /// [justPersisted] is never evicted. `persist` completing has to mean the
  /// record is stored: a clock that moved backwards would otherwise make
  /// the new record the oldest, and it would be dropped by the very call
  /// that was asked to keep it, while the caller was told it was queued.
  void _evictOverflow({required String justPersisted}) {
    while (_byKey.length > QueuedFeedbackReport.maxQueuedReports) {
      String? oldestKey;
      for (final key in _order) {
        if (key == justPersisted) continue;
        if (oldestKey == null) {
          oldestKey = key;
          continue;
        }
        if (QueuedFeedbackReport.compareByAge(
              _byKey[key]!,
              _byKey[oldestKey]!,
            ) <
            0) {
          oldestKey = key;
        }
      }
      // Only the just-persisted record remains, so the cap cannot be met
      // without discarding it — which this method refuses to do.
      if (oldestKey == null) return;
      _byKey.remove(oldestKey);
      _order.remove(oldestKey);
    }
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
