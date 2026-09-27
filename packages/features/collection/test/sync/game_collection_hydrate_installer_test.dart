import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_collection_remote.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockGameRepository extends Mock implements GameRepository {}

Future<PaginatedResult<GameCollectionWithSummary>> _empty() async =>
    const PaginatedResult(
      items: [],
      meta: PaginationMeta(
        page: 1,
        limit: 100,
        total: 0,
        totalPages: 0,
        hasMore: false,
      ),
    );

Future<PaginatedResult<GameCollectionWithSummary>> _offline() async =>
    throw const GameCollectionRemoteTransientException('offline');

const _server = ScopedServer(serverId: 'server-1', displayName: 'My Server');

void main() {
  late DependencyContainerImpl container;
  late FakeCollectionRemote remote;

  setUp(() {
    container = DependencyContainerImpl();
    remote = FakeCollectionRemote((_) => _empty());
  });

  tearDown(() async => container.dispose());

  /// Registers what the hydrate needs, less whatever a test leaves out.
  void register({
    bool client = true,
    bool collection = true,
    bool games = true,
  }) {
    // Every page is written, empty ones too, so both writes must answer.
    if (collection) {
      final repository = _MockGameCollectionRepository();
      when(() => repository.mergeFromServer(any())).thenAnswer((_) async {});
      container.registerSingleton<GameCollectionRepository>(repository);
    }
    if (games) {
      final repository = _MockGameRepository();
      when(() => repository.cachePlatformGameSummaries(any()))
          .thenAnswer((_) async {});
      container.registerSingleton<GameRepository>(repository);
    }
    if (client) {
      container.registerSingleton<GameCollectionRemoteDataSource>(remote);
    }
  }

  Future<void> install({DateTime Function()? now}) =>
      GameCollectionHydrateInstaller(now: now)
          .install(container, _server, 'user-1');

  test('install starts the hydrate', () async {
    register();
    await install();
    // The hydrate is unawaited, so let its first turn run.
    await Future<void>.delayed(Duration.zero);

    expect(remote.requests.length, 1);
  });

  test('install does not wait for the hydrate to finish', () async {
    // Activation is the bootstrap gate: awaiting the network here would put
    // it on the sign-in path.
    register();
    final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
    remote.respond = (_) => blocked.future;

    await install().timeout(const Duration(seconds: 1));

    expect(blocked.isCompleted, isFalse);
    blocked.complete(_empty());
  });

  test('install completes when the hydrate fails', () async {
    // A throw out of install() aborts activation, which signs the user out.
    register();
    remote.respond = (_) => _offline();

    await install();
    await Future<void>.delayed(Duration.zero);

    expect(remote.requests.length, 1);
  });

  group('a missing collaborator is a no-op, not a sign-out', () {
    for (final (label, registerAllBut) in <(String, void Function())>[
      ('the collection client', () => register(client: false)),
      ('the collection repository', () => register(collection: false)),
      ('the game repository', () => register(games: false)),
    ]) {
      test('without $label', () async {
        registerAllBut();

        await install();
        await Future<void>.delayed(Duration.zero);

        expect(remote.requests.length, 0);
      });
    }
  });

  group('re-hydrate registration', () {
    Future<SessionRehydrator> withRehydrator({bool client = true}) async {
      register(client: client);
      await const SessionRehydratorInstaller().install(
        container,
        _server,
        'user-1',
      );
      return container.get<SessionRehydrator>();
    }

    test('a failed pass is re-run by a later trigger', () async {
      final rehydrator = await withRehydrator();
      remote.respond = (_) => _offline();
      await install();
      await Future<void>.delayed(Duration.zero);

      // The server comes back.
      remote.respond = (_) => _empty();
      await rehydrator.rehydrateStale();

      expect(remote.requests.length, 2);
    });

    group('a completed pass', () {
      const window = GameCollectionHydrateInstaller.staleAfter;
      late DateTime clock;

      setUp(() => clock = DateTime.utc(2026, 9, 26, 12));

      Future<SessionRehydrator> completed() async {
        final rehydrator = await withRehydrator();
        await install(now: () => clock);
        await Future<void>.delayed(Duration.zero);
        return rehydrator;
      }

      test('is not re-run inside the window', () async {
        final rehydrator = await completed();

        clock = clock.add(window - const Duration(seconds: 1));
        await rehydrator.rehydrateStale();

        expect(remote.requests.length, 1);
      });

      // A session left running would otherwise never see another device's
      // changes, which #300 fixed for households.
      test('is re-run once the window has passed', () async {
        final rehydrator = await completed();

        clock = clock.add(window);
        await rehydrator.rehydrateStale();

        expect(remote.requests.length, 2);
      });

      test('a failed re-run is re-run by the next trigger', () async {
        final rehydrator = await completed();
        clock = clock.add(window);
        remote.respond = (_) => _offline();
        await rehydrator.rehydrateStale();

        remote.respond = (_) => _empty();
        await rehydrator.rehydrateStale();

        expect(remote.requests.length, 3);
      });
    });

    test('a trigger arriving during the install-time pass adds no second '
        'request', () async {
      final rehydrator = await withRehydrator();
      final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
      remote.respond = (_) => blocked.future;
      await install();

      await rehydrator.rehydrateStale();
      blocked.complete(_empty());
      await Future<void>.delayed(Duration.zero);

      expect(remote.requests.length, 1);
    });

    test('registers nothing where there is no collection client', () async {
      final rehydrator = await withRehydrator(client: false);

      await install();
      // A registered entry would be stale (it never ran) and would resolve
      // the missing client here.
      await rehydrator.rehydrateStale();

      expect(remote.requests.length, 0);
    });
  });
}
