import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_network/src/orchestration/web_server_scope_container.dart';

/// Stands in for a scoped service, so disposal order is observable.
class Probe {
  Probe(this.name, {this.log});
  final String name;
  final List<String>? log;
  bool disposed = false;

  void dispose() {
    disposed = true;
    log?.add(name);
  }
}

void main() {
  group('WebServerScopeContainer', () {
    late DependencyContainerImpl base;
    late UserScopeHost host;
    late WebServerScopeContainer container;

    setUp(() {
      base = DependencyContainerImpl();
      host = UserScopeHost(parent: () => base);
      container = WebServerScopeContainer(base: base, host: host);
    });

    test('resolves the origin scope when no session is open', () {
      final origin = Probe('origin');
      base.registerSingleton<Probe>(origin);

      expect(container.get<Probe>(), same(origin));
      expect(container.isRegistered<Probe>(), isTrue);
    });

    test('throws for an unregistered type, like any container', () {
      expect(container.get<Probe>, throwsStateError);
      expect(container.isRegistered<Probe>(), isFalse);
    });

    test('sees into the open user scope', () async {
      await host.open((view) async => view.registerSingleton<int>(7));

      expect(container.get<int>(), 7);
      expect(container.isRegistered<int>(), isTrue);
    });

    test('the user scope shadows the origin scope', () async {
      base.registerSingleton<String>('origin');
      await host.open((view) async => view.registerSingleton<String>('user'));

      expect(container.get<String>(), 'user');
    });

    test('still falls through to the origin scope during a session', () async {
      final origin = Probe('origin');
      base.registerSingleton<Probe>(origin);
      await host.open((view) async => view.registerSingleton<int>(7));

      expect(container.get<Probe>(), same(origin));
      expect(container.isRegistered<Probe>(), isTrue);
    });

    test('a closed session stops being visible', () async {
      await host.open((view) async => view.registerSingleton<int>(7));
      await host.close();

      expect(container.isRegistered<int>(), isFalse);
      expect(container.get<int>, throwsStateError);
    });

    test('registrations land in the origin scope, never the session', () async {
      await host.open((_) async {});

      container.registerSingleton<String>('written');

      // Survives the session it was written during: this handle cannot
      // accidentally give something a per-user lifetime.
      await host.close();
      expect(container.get<String>(), 'written');
      expect(base.get<String>(), 'written');
    });

    test('lazy singletons and factories reach the origin scope too', () {
      container.registerLazySingleton<int>(() => 1);
      container.registerFactory<String>(() => 'made');

      expect(container.get<int>(), 1);
      expect(container.get<String>(), 'made');
      expect(base.isRegistered<int>(), isTrue);
    });

    group('dispose', () {
      test('closes the user scope before the origin scope', () async {
        // Per-user services hold resources the origin scope owns — the
        // ServerDatabase above all — so they have to release before it
        // closes underneath them.
        final order = <String>[];
        base.registerSingleton<Probe>(
          Probe('origin', log: order),
          dispose: (p) => p.dispose(),
        );
        await host.open(
          (view) async =>
              view.registerSingleton<int>(7, dispose: (_) => order.add('user')),
        );

        await container.dispose();

        expect(order, ['user', 'origin']);
      });

      test('disposes the origin scope with no session open', () async {
        final origin = Probe('origin');
        base.registerSingleton<Probe>(origin, dispose: (p) => p.dispose());

        await container.dispose();

        expect(origin.disposed, isTrue);
      });

      test(
        'a throwing user-scope teardown still disposes the origin scope',
        () async {
          // Both halves always run; the first error is what surfaces.
          final origin = Probe('origin');
          base.registerSingleton<Probe>(origin, dispose: (p) => p.dispose());
          await host.open(
            (view) async => view.registerSingleton<int>(
              7,
              dispose: (_) => throw StateError('user teardown blew up'),
            ),
          );

          await expectLater(container.dispose(), throwsStateError);

          expect(origin.disposed, isTrue);
        },
      );
    });
  });
}
