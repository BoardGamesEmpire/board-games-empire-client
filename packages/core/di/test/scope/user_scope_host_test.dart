import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';

/// Probe registered into a scope so tests can observe disposal.
class Probe {
  Probe(this.name);
  final String name;
  bool disposed = false;
}

/// Container whose `dispose()` throws after tearing itself down — stands in
/// for a service whose `dispose:` callback misbehaves.
class ThrowingDisposeContainer implements DependencyContainer {
  ThrowingDisposeContainer(this._inner);

  final DependencyContainer _inner;
  var disposeCalls = 0;

  @override
  T get<T extends Object>() => _inner.get<T>();

  @override
  bool isRegistered<T extends Object>() => _inner.isRegistered<T>();

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    void Function(T instance)? dispose,
  }) => _inner.registerSingleton<T>(instance, dispose: dispose);

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    void Function(T instance)? dispose,
  }) => _inner.registerLazySingleton<T>(factory, dispose: dispose);

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      _inner.registerFactory<T>(factory);

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _inner.dispose();
    throw StateError('dispose callback blew up');
  }
}

void main() {
  group('UserScopeHost', () {
    late DependencyContainer parent;
    late UserScopeHost host;

    setUp(() {
      parent = DependencyContainerImpl();
      host = UserScopeHost(parent: () => parent);
    });

    test('starts with no active scope', () {
      expect(host.isActive, isFalse);
      expect(host.scope, isNull);
    });

    test('open hands install a view that writes to the child scope', () async {
      final base = Probe('base');
      parent.registerSingleton<Probe>(base);

      late DependencyContainer view;
      await host.open((v) async {
        view = v;
        v.registerSingleton<int>(7);
      });

      expect(host.isActive, isTrue);
      // The registration landed in the child, not the parent.
      expect(host.scope!.isRegistered<int>(), isTrue);
      expect(parent.isRegistered<int>(), isFalse);
      // Resolution through the view falls through to the parent.
      expect(view.get<Probe>(), same(base));
      expect(view.get<int>(), 7);
      expect(view.isRegistered<Probe>(), isTrue);
    });

    test('the view resolves the parent at call time, not at open', () async {
      late DependencyContainer view;
      await host.open((v) async => view = v);

      final replacement = DependencyContainerImpl()
        ..registerSingleton<String>('swapped');
      parent = replacement;

      expect(view.get<String>(), 'swapped');
      expect(view.isRegistered<String>(), isTrue);
    });

    test('a child registration shadows the parent', () async {
      parent.registerSingleton<String>('parent');
      late DependencyContainer view;
      await host.open((v) async {
        view = v;
        v.registerSingleton<String>('child');
      });

      expect(view.get<String>(), 'child');
    });

    test('installers see what earlier installers registered', () async {
      // Two genuinely separate installers run in order through one view:
      // the second resolves what the first registered, alongside a
      // parent-lifetime service, through the same handle.
      parent.registerSingleton<String>('parent-service');
      final order = <String>[];

      Future<void> first(DependencyContainer c) async {
        order.add('first');
        c.registerSingleton<int>(1);
      }

      Future<void> second(DependencyContainer c) async {
        order.add('second');
        // Registered by `first`, into the child.
        expect(c.get<int>(), 1);
        // Resolved by falling through to the parent.
        expect(c.get<String>(), 'parent-service');
        c.registerSingleton<double>(c.get<int>() + 0.5);
      }

      await host.open((v) async {
        for (final installer in [first, second]) {
          await installer(v);
        }
      });

      expect(order, ['first', 'second']);
      expect(host.scope!.get<double>(), 1.5);
    });

    test('the view refuses disposal — the host owns the lifecycle', () async {
      late DependencyContainer view;
      await host.open((v) async => view = v);

      expect(view.dispose, throwsUnsupportedError);
      expect(host.isActive, isTrue);
    });

    test('open throws when a scope is already active', () async {
      await host.open((_) async {});

      await expectLater(host.open((_) async {}), throwsStateError);
      // The pre-existing scope survives the rejected call.
      expect(host.isActive, isTrue);
    });

    test('close disposes the child and detaches it', () async {
      final probe = Probe('user');
      await host.open((v) async {
        v.registerSingleton<Probe>(probe, dispose: (p) => p.disposed = true);
      });

      await host.close();

      expect(probe.disposed, isTrue);
      expect(host.isActive, isFalse);
      expect(host.scope, isNull);
    });

    test('close is a no-op when no scope is active', () async {
      await host.close();
      await host.close();
      expect(host.isActive, isFalse);
    });

    test('close leaves the parent scope untouched', () async {
      final base = Probe('base');
      parent.registerSingleton<Probe>(base, dispose: (p) => p.disposed = true);
      await host.open((v) async => v.registerSingleton<int>(1));

      await host.close();

      expect(base.disposed, isFalse);
      expect(parent.get<Probe>(), same(base));
    });

    test('a failing install discards the partial scope and rethrows', () async {
      final base = Probe('base');
      parent.registerSingleton<Probe>(base, dispose: (p) => p.disposed = true);
      final partial = Probe('partial');

      await expectLater(
        host.open((v) async {
          v.registerSingleton<Probe>(
            partial,
            dispose: (p) => p.disposed = true,
          );
          throw StateError('installer failed');
        }),
        throwsStateError,
      );

      expect(partial.disposed, isTrue, reason: 'partial scope discarded');
      expect(base.disposed, isFalse, reason: 'parent scope untouched');
      expect(host.isActive, isFalse);
    });

    test('a retry after a failed install starts from a clean scope', () async {
      await expectLater(
        host.open((v) async {
          v.registerSingleton<int>(1);
          throw StateError('installer failed');
        }),
        throwsStateError,
      );

      await host.open((v) async => v.registerSingleton<int>(2));

      expect(host.scope!.get<int>(), 2);
    });

    test(
      'a throwing teardown cannot mask the original install error',
      () async {
        final throwing = <ThrowingDisposeContainer>[];
        final host = UserScopeHost(
          parent: () => parent,
          childFactory: () {
            final c = ThrowingDisposeContainer(DependencyContainerImpl());
            throwing.add(c);
            return c;
          },
        );

        await expectLater(
          host.open((_) async => throw ArgumentError('installer failed')),
          throwsArgumentError,
        );

        expect(throwing.single.disposeCalls, 1);
        expect(host.isActive, isFalse);
      },
    );

    test('a scope can be reopened after close', () async {
      await host.open((v) async => v.registerSingleton<int>(1));
      await host.close();
      await host.open((v) async => v.registerSingleton<int>(2));

      expect(host.scope!.get<int>(), 2);
    });

    test(
      'hosts a user scope over a plain container — no ServerContext in sight',
      () async {
        // The #289 acceptance: the primitive is reachable from a composition
        // root that is not ServerContextImpl. This is the shape web's holder
        // takes over its single origin-scoped container (#137).
        final origin = DependencyContainerImpl()
          ..registerSingleton<String>('origin-service');
        final webHost = UserScopeHost(parent: () => origin);
        final perUser = Probe('web-user');

        await webHost.open((v) async {
          expect(v.get<String>(), 'origin-service');
          v.registerSingleton<Probe>(
            perUser,
            dispose: (p) => p.disposed = true,
          );
        });

        expect(webHost.scope!.get<Probe>(), same(perUser));

        await webHost.close();

        expect(perUser.disposed, isTrue);
        expect(origin.get<String>(), 'origin-service');
      },
    );
  });
}
