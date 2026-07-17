import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

class _RecordingSink implements LogSink {
  final List<LogRecord> emitted = [];
  bool closed = false;

  @override
  void emit(LogRecord record) => emitted.add(record);

  @override
  Future<void> close() async => closed = true;
}

class _ThrowingSink implements LogSink {
  @override
  void emit(LogRecord record) => throw StateError('boom');

  @override
  Future<void> close() async => throw StateError('boom');
}

void main() {
  group('CompositeLogSink', () {
    test('fans every record out to all children', () {
      final a = _RecordingSink();
      final b = _RecordingSink();
      CompositeLogSink([a, b]).emit(LogRecord(Level.INFO, 'hi', 'bge.x'));
      expect(a.emitted, hasLength(1));
      expect(b.emitted, hasLength(1));
    });

    test('a throwing child neither starves the others nor throws', () {
      final good = _RecordingSink();
      final composite = CompositeLogSink([_ThrowingSink(), good]);
      expect(
        () => composite.emit(LogRecord(Level.INFO, 'hi', 'bge.x')),
        returnsNormally,
      );
      expect(good.emitted, hasLength(1));
    });

    test('close awaits every child even when one throws', () async {
      final a = _RecordingSink();
      final b = _RecordingSink();
      await CompositeLogSink([a, _ThrowingSink(), b]).close();
      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
    });
  });
}
