import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

/// Captures every record it is handed, and whether it was closed.
class _RecordingSink implements LogSink {
  final List<LogRecord> emitted = [];
  bool closed = false;

  @override
  void emit(LogRecord record) => emitted.add(record);

  @override
  Future<void> close() async => closed = true;
}

void main() {
  tearDown(ShellObservability.reset);

  group('ShellObservability log sink wiring (#100)', () {
    test('forwards records at or above the console threshold', () {
      final sink = _RecordingSink();
      ShellObservability.initialize(
        sink: sink,
        consoleThreshold: BgeLogLevel.warn,
      );

      BgeLogger('bge.test.sink').warn('reaches the console');

      expect(
        sink.emitted.map((r) => r.message),
        contains('reaches the console'),
      );
    });

    test('drops records below the console threshold', () {
      final sink = _RecordingSink();
      ShellObservability.initialize(
        sink: sink,
        consoleThreshold: BgeLogLevel.warn,
      );

      BgeLogger('bge.test.sink').info('below threshold');

      expect(
        sink.emitted.where((r) => r.message == 'below threshold'),
        isEmpty,
      );
    });

    test('breadcrumbs still capture everything even when the sink gate is '
        'warn — the ring, not the gate, is the retention policy', () {
      final sink = _RecordingSink();
      ShellObservability.initialize(
        sink: sink,
        consoleThreshold: BgeLogLevel.warn,
      );

      BgeLogger('bge.test.sink').info('info-level detail');

      expect(
        ShellObservability.breadcrumbs.snapshot().where(
          (c) => c.message == 'info-level detail',
        ),
        hasLength(1),
      );
    });

    test('the default threshold (verbose) forwards even verbose records', () {
      final sink = _RecordingSink();
      ShellObservability.initialize(sink: sink);

      BgeLogger('bge.test.sink').verbose('fine-grained');

      expect(sink.emitted.map((r) => r.message), contains('fine-grained'));
    });

    test(
      'reset closes the sink so a file sink flushes and cannot leak',
      () async {
        final sink = _RecordingSink();
        ShellObservability.initialize(sink: sink);

        await ShellObservability.reset();

        expect(sink.closed, isTrue);
      },
    );
  });
}
