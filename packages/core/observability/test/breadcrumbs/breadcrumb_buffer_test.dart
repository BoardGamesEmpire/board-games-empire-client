import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    Logger.root.level = Level.ALL;
  });

  tearDown(() {
    Logger.root.level = Level.INFO;
  });

  group('BreadcrumbBuffer ring semantics', () {
    test('capacity must be positive', () {
      expect(() => BreadcrumbBuffer(capacity: 0), throwsA(isA<AssertionError>()));
    });

    test('captures records in order up to capacity', () {
      final buffer = BreadcrumbBuffer(capacity: 5)..attach();
      addTearDown(buffer.detach);
      final logger = BgeLogger('bge.test.order');
      logger
        ..info('one')
        ..info('two')
        ..info('three');
      expect(buffer.length, 3);
      expect(buffer.snapshot().map((b) => b.message).toList(), [
        'one',
        'two',
        'three',
      ]);
    });

    test('evicts oldest entries beyond capacity', () {
      final buffer = BreadcrumbBuffer(capacity: 3)..attach();
      addTearDown(buffer.detach);
      final logger = BgeLogger('bge.test.evict');
      for (var i = 1; i <= 5; i++) {
        logger.info('msg $i');
      }
      expect(buffer.length, 3);
      expect(buffer.snapshot().map((b) => b.message).toList(), [
        'msg 3',
        'msg 4',
        'msg 5',
      ]);
    });

    test('clear empties the buffer without detaching', () {
      final buffer = BreadcrumbBuffer(capacity: 3)..attach();
      addTearDown(buffer.detach);
      final logger = BgeLogger('bge.test.clear');
      logger.info('before');
      buffer.clear();
      expect(buffer.length, 0);
      logger.info('after');
      expect(buffer.snapshot().single.message, 'after');
    });

    test('snapshot is an unmodifiable copy', () {
      final buffer = BreadcrumbBuffer(capacity: 3)..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.snapshot').info('only');
      final snap = buffer.snapshot();
      expect(() => snap.clear(), throwsUnsupportedError);
      // A later record does not retroactively appear in the old snapshot.
      BgeLogger('bge.test.snapshot').info('later');
      expect(snap, hasLength(1));
    });
  });

  group('BreadcrumbBuffer attach/detach', () {
    test('records are not captured before attach or after detach', () async {
      final buffer = BreadcrumbBuffer(capacity: 5);
      final logger = BgeLogger('bge.test.lifecycle');
      logger.info('pre-attach');
      expect(buffer.length, 0);

      buffer.attach();
      logger.info('attached');
      expect(buffer.length, 1);

      await buffer.detach();
      logger.info('post-detach');
      expect(buffer.length, 1);
    });

    test('attach is idempotent (no double capture)', () {
      final buffer = BreadcrumbBuffer(capacity: 5)
        ..attach()
        ..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.idempotent').info('once');
      expect(buffer.length, 1);
    });
  });

  group('BreadcrumbBuffer record mapping', () {
    test('captures timestamp, level, and logger name', () {
      final buffer = BreadcrumbBuffer(capacity: 5)..attach();
      addTearDown(buffer.detach);
      final before = DateTime.now();
      BgeLogger('bge.test.mapping').warn('careful');
      final crumb = buffer.snapshot().single;
      expect(crumb.level, BgeLogLevel.warn);
      expect(crumb.loggerName, 'bge.test.mapping');
      expect(
        crumb.timestamp.isBefore(before.subtract(const Duration(seconds: 5))),
        isFalse,
      );
    });

    test('masks emails embedded in the message', () {
      final buffer = BreadcrumbBuffer(capacity: 5)..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.pii').info('sign-in failed for john.doe@email.com');
      expect(
        buffer.snapshot().single.message,
        'sign-in failed for j**n.d*e@email.com',
      );
    });

    test('sanitizes default-redacted keys from a context map', () {
      final buffer = BreadcrumbBuffer(capacity: 5)..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.ctx').info(
        'auth attempt',
        context: {'password': 'hunter2', 'attempt': 2},
      );
      final crumb = buffer.snapshot().single;
      expect(crumb.sanitizedContext, {
        'password': '<redacted>',
        'attempt': 2,
      });
    });

    test('sanitizes nested context maps', () {
      final buffer = BreadcrumbBuffer(capacity: 5)..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.nested').info(
        'request',
        context: {
          'headers': {'authorization': 'Bearer abc', 'accept': 'json'},
        },
      );
      expect(buffer.snapshot().single.sanitizedContext, {
        'headers': {'authorization': '<redacted>', 'accept': 'json'},
      });
    });

    test('custom redactedContextFields override the defaults', () {
      final buffer = BreadcrumbBuffer(
        capacity: 5,
        redactedContextFields: {'shoeSize'},
      )..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.custom').info(
        'profile',
        context: {'shoeSize': 44, 'password': 'visible-now'},
      );
      expect(buffer.snapshot().single.sanitizedContext, {
        'shoeSize': '<redacted>',
        'password': 'visible-now',
      });
    });

    test('records without context have a null sanitizedContext', () {
      final buffer = BreadcrumbBuffer(capacity: 5)..attach();
      addTearDown(buffer.detach);
      BgeLogger('bge.test.noctx').info('plain');
      expect(buffer.snapshot().single.sanitizedContext, isNull);
    });
  });

  group('Breadcrumb JSON', () {
    test('round-trips through toJson/fromJson', () {
      final crumb = Breadcrumb(
        timestamp: DateTime.utc(2026, 6, 12, 10, 30),
        level: BgeLogLevel.debug,
        loggerName: 'bge.test.json',
        message: 'hello',
        sanitizedContext: const {'k': 'v'},
      );
      expect(Breadcrumb.fromJson(crumb.toJson()), crumb);
    });

    test('level serialises to its camelCase wire string', () {
      final crumb = Breadcrumb(
        timestamp: DateTime.utc(2026),
        level: BgeLogLevel.warn,
        loggerName: 'bge.test.wire',
        message: 'm',
      );
      expect(crumb.toJson()['level'], 'warn');
    });
  });
}
