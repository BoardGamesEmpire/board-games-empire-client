import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('DeveloperLogSink', () {
    late List<_Call> calls;
    late DeveloperLogSink sink;

    setUp(() {
      calls = [];
      sink = DeveloperLogSink(
        logFn: (message, {time, level = 0, name = '', error, stackTrace}) {
          calls.add(_Call(message, level, name, error));
        },
      );
    });

    test('forwards message, numeric level, and logger name', () {
      sink.emit(LogRecord(Level.WARNING, 'careful', 'bge.x'));
      expect(calls, hasLength(1));
      expect(calls.single.message, 'careful');
      expect(calls.single.level, Level.WARNING.value);
      expect(calls.single.name, 'bge.x');
    });

    test('a real error takes the error slot; context appends to message', () {
      const payload = ContextLogMessage('op failed', {'code': 503});
      final error = StateError('kaboom');
      sink.emit(
        LogRecord(
          Level.SEVERE,
          payload.toString(),
          'bge.x',
          error,
          null,
          null,
          payload,
        ),
      );
      expect(calls.single.error, same(error));
      expect(calls.single.message, 'op failed {"code":503}');
    });

    test('with no error, the context map itself rides the error slot', () {
      const payload = ContextLogMessage('op', {'code': 503});
      sink.emit(
        LogRecord(
          Level.INFO,
          payload.toString(),
          'bge.x',
          null,
          null,
          null,
          payload,
        ),
      );
      expect(calls.single.error, {'code': 503});
      expect(calls.single.message, 'op');
    });

    test('no error and no context leaves the error slot null', () {
      sink.emit(LogRecord(Level.INFO, 'plain', 'bge.x'));
      expect(calls.single.error, isNull);
    });
  });
}

class _Call {
  _Call(this.message, this.level, this.name, this.error);
  final String message;
  final int level;
  final String name;
  final Object? error;
}
