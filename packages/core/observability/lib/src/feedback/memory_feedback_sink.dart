import 'feedback_report.dart';
import 'feedback_sink.dart';

/// RAM implementation of [FeedbackSink] (#69).
///
/// Two jobs: the **web stand-in** until #63 gives web a durable store
/// (an approved-but-unsent report survives within the session and is
/// lost on reload — the prompt tells the user so), and `runBgeApp`'s
/// resolve-or-default fallback when a platform module registered no
/// sink. Nothing about a RAM sink is platform-specific, so it lives in
/// `observability`.
///
/// Insertion order is preserved so [pending] drains oldest-first.
class MemoryFeedbackSink implements FeedbackSink {
  final Map<String, FeedbackReport> _byKey = {};
  final List<String> _order = [];

  @override
  Future<void> persist(FeedbackReport report) async {
    final key = report.correlationKey;
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        report.correlationKey,
        'report.correlationKey',
        'MemoryFeedbackSink requires a correlationKey',
      );
    }
    if (!_byKey.containsKey(key)) _order.add(key);
    _byKey[key] = report;
  }

  @override
  Future<List<FeedbackReport>> pending() async => [
    for (final key in _order) _byKey[key]!,
  ];

  @override
  Future<void> remove(String correlationKey) async {
    if (_byKey.remove(correlationKey) != null) {
      _order.remove(correlationKey);
    }
  }
}
