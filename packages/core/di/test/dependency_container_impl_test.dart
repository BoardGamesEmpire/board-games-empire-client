import 'package:flutter_test/flutter_test.dart';
import 'package:di/di.dart';
import 'package:get_it/get_it.dart';

class _FakeService {}

class _OtherService {}

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

    /// Red-phase tests for the external-GetIt constructor (issue #72).
    ///
    /// Design decisions pinned here (see #72 / #61 for rationale):
    ///
    /// - **injectable-ready seam.** injectable's generated `init` is an
    ///   extension on [GetIt], so a composition root must be able to
    ///   create the instance itself, run generated init on it, and wrap
    ///   it in the [DependencyContainer] abstraction consumers already
    ///   use. Registrations must be visible in both directions across
    ///   the wrapper boundary.
    /// - **Never the global instance.** The root container is always its
    ///   own `GetIt.asNewInstance()`; wrapping must not leak anything
    ///   into `GetIt.instance`.
    /// - **Single owner.** Disposing the wrapper resets the wrapped
    ///   instance (callbacks fire, registrations gone) — the wrapper is
    ///   the instance's lifecycle owner, not a view.
    group('DependencyContainerImpl.fromGetIt', () {
      late GetIt getIt;
      late DependencyContainerImpl wrapper;

      setUp(() {
        getIt = GetIt.asNewInstance();
        wrapper = DependencyContainerImpl.fromGetIt(getIt);
      });

      tearDown(() async => wrapper.dispose());

      test('registrations made through the wrapper resolve through the '
          'wrapped GetIt directly', () {
        final instance = _FakeService();
        wrapper.registerSingleton<_FakeService>(instance);

        expect(getIt.get<_FakeService>(), same(instance));
      });

      test('registrations made directly on the wrapped GetIt resolve '
          'through the wrapper — the seam injectable\'s generated init '
          'relies on', () {
        final instance = _OtherService();
        getIt.registerSingleton<_OtherService>(instance);

        expect(wrapper.isRegistered<_OtherService>(), isTrue);
        expect(wrapper.get<_OtherService>(), same(instance));
      });

      test('never touches the global GetIt.instance', () {
        wrapper.registerSingleton<_FakeService>(_FakeService());

        expect(GetIt.instance.isRegistered<_FakeService>(), isFalse);
      });

      test('rejects the global GetIt.instance in all build modes — the '
          'never-global contract enforced at the seam even in release', () {
        expect(
          () => DependencyContainerImpl.fromGetIt(GetIt.instance),
          throwsArgumentError,
        );
        // The check fires before any registration, so nothing leaks into
        // the global instance.
        expect(GetIt.instance.isRegistered<_FakeService>(), isFalse);
      });

      test('dispose resets the wrapped instance and fires dispose '
          'callbacks supplied at registration', () async {
        var disposed = false;
        wrapper.registerSingleton<_FakeService>(
          _FakeService(),
          dispose: (_) => disposed = true,
        );

        await wrapper.dispose();

        expect(disposed, isTrue);
        expect(getIt.isRegistered<_FakeService>(), isFalse);
      });

      test('the disposed guard applies to a wrapping container', () async {
        await wrapper.dispose();

        expect(() => wrapper.get<_FakeService>(), throwsStateError);
        expect(
          () => wrapper.registerSingleton<_FakeService>(_FakeService()),
          throwsStateError,
        );
      });
    });
  });
}
