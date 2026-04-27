import 'package:flutter_test/flutter_test.dart';
import 'package:di/di.dart';

class _FakeService {}

void main() {
  late DependencyContainerImpl container;

  setUp(() => container = DependencyContainerImpl());
  tearDown(() async => container.dispose());

  group('DependencyContainerImpl', () {
    group('registerSingleton / get', () {
      test('returns the same instance on every call', () {
        final instance = _FakeService();
        container.registerSingleton<_FakeService>(instance);

        expect(container.get<_FakeService>(), same(instance));
        expect(container.get<_FakeService>(), same(instance));
      });

      test('throws when type not registered', () {
        expect(() => container.get<_FakeService>(), throwsA(isA<Error>()));
      });
    });

    group('registerLazySingleton', () {
      test('calls factory only once', () {
        int callCount = 0;
        container.registerLazySingleton<_FakeService>(() {
          callCount++;
          return _FakeService();
        });

        container.get<_FakeService>();
        container.get<_FakeService>();

        expect(callCount, 1);
      });

      test('returns same instance on subsequent calls', () {
        container.registerLazySingleton<_FakeService>(_FakeService.new);

        final a = container.get<_FakeService>();
        final b = container.get<_FakeService>();

        expect(a, same(b));
      });
    });

    group('registerFactory', () {
      test('returns a new instance on each call', () {
        container.registerFactory<_FakeService>(_FakeService.new);

        final a = container.get<_FakeService>();
        final b = container.get<_FakeService>();

        expect(a, isNot(same(b)));
      });
    });

    group('isRegistered', () {
      test('returns true after registration', () {
        container.registerSingleton<_FakeService>(_FakeService());
        expect(container.isRegistered<_FakeService>(), isTrue);
      });

      test('returns false for unregistered type', () {
        expect(container.isRegistered<_FakeService>(), isFalse);
      });
    });

    group('dispose', () {
      test('is idempotent — second call does not throw', () async {
        await container.dispose();
        await expectLater(container.dispose(), completes);
      });

      test('throws on get after disposal', () async {
        container.registerSingleton<_FakeService>(_FakeService());
        await container.dispose();

        expect(() => container.get<_FakeService>(), throwsStateError);
      });

      test('throws on register after disposal', () async {
        await container.dispose();

        expect(
          () => container.registerSingleton<_FakeService>(_FakeService()),
          throwsStateError,
        );
      });
    });

    group('isolation', () {
      test('two containers do not share registrations', () {
        final other = DependencyContainerImpl();
        container.registerSingleton<_FakeService>(_FakeService());

        expect(other.isRegistered<_FakeService>(), isFalse);

        other.dispose();
      });
    });
  });
}
