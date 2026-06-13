import 'dart:async';

import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> subscription;

  setUp(() {
    Logger.root.level = Level.ALL;
    records = [];
    subscription = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await subscription.cancel();
    Logger.root.level = Level.INFO;
  });

  group('BgeLogger', () {
    test('exposes its hierarchical name', () {
      final logger = BgeLogger('bge.storage.sync_queue');
      expect(logger.name, 'bge.storage.sync_queue');
    });

    test('records propagate to the root logger with the logger name', () {
      BgeLogger('bge.test.propagation').info('hello');
      expect(records, hasLength(1));
      expect(records.single.loggerName, 'bge.test.propagation');
      expect(records.single.message, 'hello');
    });

    test('each method emits at its mapped package:logging level', () {
      final logger = BgeLogger('bge.test.levels');
      logger
        ..verbose('v')
        ..debug('d')
        ..info('i')
        ..warn('w')
        ..error('e');
      expect(records.map((r) => r.level).toList(), [
        Level.FINEST,
        Level.FINE,
        Level.INFO,
        Level.WARNING,
        Level.SEVERE,
      ]);
    });

    test('error and stackTrace pass through to the record', () {
      final logger = BgeLogger('bge.test.error');
      final boom = StateError('boom');
      final trace = StackTrace.current;
      logger.error('failed', error: boom, stackTrace: trace);
      expect(records.single.error, same(boom));
      expect(records.single.stackTrace, same(trace));
    });

    test('context map travels on record.object as a ContextLogMessage', () {
      final logger = BgeLogger('bge.test.context');
      logger.info('with ctx', context: {'requestId': 'r-1'});
      final object = records.single.object;
      expect(object, isA<ContextLogMessage>());
      expect((object! as ContextLogMessage).context, {'requestId': 'r-1'});
      // The record message stays the plain text — handlers that only
      // print record.message are unaffected by the context payload.
      expect(records.single.message, 'with ctx');
    });

    test('omitted or empty context emits a plain String message', () {
      final logger = BgeLogger('bge.test.nocontext');
      logger
        ..info('plain')
        ..info('empty', context: {});
      expect(records[0].object, isNull);
      expect(records[1].object, isNull);
    });
  });

  group('ContextLogMessage', () {
    test('toString returns the text only', () {
      const message = ContextLogMessage('text', {'k': 'v'});
      expect(message.toString(), 'text');
    });
  });
}
