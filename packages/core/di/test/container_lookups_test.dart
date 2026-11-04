import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

class _Optional {}

void main() {
  late DependencyContainerImpl container;
  late List<LogRecord> records;

  setUp(() {
    container = DependencyContainerImpl();
    addTearDown(container.dispose);
    records = [];
    // SEVERE already clears logging's default INFO threshold, so the root
    // level is left alone rather than leaked into later tests.
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
  });

  List<LogRecord> lookupRecords() =>
      records.where((r) => r.loggerName == 'bge.di.lookup').toList();

  group('tryGet (#218)', () {
    test('returns null and logs nothing when T is not registered', () {
      expect(container.tryGet<_Optional>(), isNull);
      expect(lookupRecords(), isEmpty);
    });

    test('returns the instance when the factory succeeds', () {
      final instance = _Optional();
      container.registerLazySingleton<_Optional>(() => instance);

      expect(container.tryGet<_Optional>(), same(instance));
      expect(lookupRecords(), isEmpty);
    });

    test('returns null and logs one error naming T when the lazy factory '
        'throws', () {
      final boom = StateError('boom');
      container.registerLazySingleton<_Optional>(() => throw boom);

      expect(container.tryGet<_Optional>(), isNull);

      final logged = lookupRecords();
      expect(logged, hasLength(1));
      expect(logged.single.level, Level.SEVERE);
      expect(logged.single.message, contains('_Optional'));
      expect(logged.single.error, same(boom));
    });

    test('retries the factory on the next call after a throw', () {
      final instance = _Optional();
      var calls = 0;
      container.registerLazySingleton<_Optional>(() {
        calls++;
        if (calls == 1) throw StateError('transient');
        return instance;
      });

      expect(container.tryGet<_Optional>(), isNull);
      expect(container.tryGet<_Optional>(), same(instance));
      expect(calls, 2);
    });

    test('returns null on a disposed container', () async {
      container.registerSingleton<_Optional>(_Optional());
      await container.dispose();

      expect(container.tryGet<_Optional>(), isNull);
    });
  });
}
