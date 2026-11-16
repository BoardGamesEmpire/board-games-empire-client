import 'dart:async';

import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/list_items.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

const _lockedKeys = {
  'gameId',
  'platformGameId',
  'title',
  'platformName',
  'medium',
  'quantity',
  'releaseId',
  'rating',
  'comment',
  'playAgain',
  'favorite',
  'playCount',
  'lastPlayed',
  'createdAt',
  'updatedAt',
};

void main() {
  late DependencyContainerImpl container;
  late _MockGameCollectionRepository repository;
  late ActiveServer server;
  late List<String> calls;

  setUp(() {
    container = DependencyContainerImpl();
    addTearDown(container.dispose);
    repository = _MockGameCollectionRepository();
    calls = [];
    server = ActiveServer(
      serverId: 'local-1',
      displayName: 'Server',
      identity: testServerIdentity(),
      container: container,
    );
  });

  void rows(List<GameCollectionListItem> items) {
    when(() => repository.watchCollectionListItems()).thenAnswer((_) {
      calls.add('read');
      return Stream.value(items);
    });
  }

  GameCollectionHydrationStatus registerStatus({DateTime Function()? now}) {
    final status = GameCollectionHydrationStatus(now: now);
    addTearDown(status.close);
    container.registerSingleton<GameCollectionHydrationStatus>(status);
    return status;
  }

  group('GameCollectionExporter', () {
    const exporter = GameCollectionExporter();

    test('names its category and the two label keys', () {
      expect(exporter.key, 'gameCollection');
      expect(exporter.categoryNameKey, 'collectionExportName');
      expect(exporter.descriptionKey, 'collectionExportDescription');
    });

    test('returns null when the server has no collection repository', () async {
      expect(await exporter.export(server), isNull);
    });

    test('an empty collection exports an empty entries list', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      rows(const []);

      final export = await exporter.export(server);

      expect(export!.data, {'entries': <Object?>[]});
    });

    test('an entry carries exactly the locked keys', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      rows([listItem('a')]);

      final export = await exporter.export(server);

      final entries = export!.data['entries']! as List<Object?>;
      final entry = entries.single! as Map<String, Object?>;
      expect(entry.keys.toSet(), _lockedKeys);
      expect(entry.keys.toList(), _lockedKeys.toList());
    });

    test('values are projected from the row', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      // The same instant as 2026-01-02T03:04:05Z, held as a local time.
      final created = DateTime.utc(2026, 1, 2, 3, 4, 5).toLocal();
      expect(created.isUtc, isFalse);
      final base = listItem(
        'a',
        title: 'Azul',
        quantity: 2,
        rating: 9,
        favorite: true,
      );
      rows([
        base.copyWith(
          entry: base.entry.copyWith(
            createdAt: created,
            comment: 'Great',
            releaseId: 'r-1',
            playAgain: true,
            playCount: 4,
          ),
        ),
      ]);

      final export = await exporter.export(server);

      final entry =
          (export!.data['entries']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(entry, {
        'gameId': 'g-a',
        'platformGameId': 'pg-a',
        'title': 'Azul',
        'platformName': 'Board game',
        'medium': 'Physical',
        'quantity': 2,
        'releaseId': 'r-1',
        'rating': 9,
        'comment': 'Great',
        'playAgain': true,
        'favorite': true,
        'playCount': 4,
        'lastPlayed': null,
        'createdAt': '2026-01-02T03:04:05.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
      });
    });

    test('lastPlayed is exported as a UTC instant when set', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      rows([listItem('a', lastPlayed: DateTime.utc(2026, 3, 4, 5, 6, 7))]);

      final export = await exporter.export(server);

      final entry =
          (export!.data['entries']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(entry['lastPlayed'], '2026-03-04T05:06:07.000Z');
    });

    test('an unsynced entry is included', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      final base = listItem('a');
      rows([
        base.copyWith(
          entry: base.entry.copyWith(isLocalOnly: true, isDirty: true),
        ),
      ]);

      final export = await exporter.export(server);

      final entry =
          (export!.data['entries']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(entry['gameId'], 'g-a');
      expect(entry.containsKey('isLocalOnly'), isFalse);
      expect(entry.containsKey('isDirty'), isFalse);
    });

    group('confirmed only when the last pass refreshed', () {
      setUp(() {
        container.registerSingleton<GameCollectionRepository>(repository);
        rows(const []);
      });

      test('refreshed', () async {
        registerStatus().finished(CollectionHydrateOutcome.complete);

        expect((await exporter.export(server))!.confirmed, isTrue);
      });

      test('failed', () async {
        registerStatus().finished(CollectionHydrateOutcome.failed);

        expect((await exporter.export(server))!.confirmed, isFalse);
      });

      test('idle', () async {
        registerStatus();

        expect((await exporter.export(server))!.confirmed, isFalse);
      });

      test('no status registered', () async {
        expect((await exporter.export(server))!.confirmed, isFalse);
      });

      group('as it read before the rows', () {
        void passDuringRead(void Function() pass) {
          when(() => repository.watchCollectionListItems()).thenAnswer((_) {
            calls.add('read');
            pass();
            return Stream.value(const []);
          });
        }

        test('a pass that lands during the read does not confirm rows '
            'read before it', () async {
          final status = registerStatus()
            ..finished(CollectionHydrateOutcome.failed);
          passDuringRead(() {
            status
              ..started()
              ..finished(CollectionHydrateOutcome.complete);
          });

          final export = await exporter.export(server);

          expect(calls, ['read']);
          expect(status.state, HydrationState.refreshed);
          expect(export!.confirmed, isFalse);
        });

        test('a pass that starts during the read does not unconfirm rows a '
            'recent one landed', () async {
          final status = registerStatus()
            ..finished(CollectionHydrateOutcome.complete);
          passDuringRead(status.started);

          final export = await exporter.export(server);

          expect(calls, ['read']);
          expect(status.state, HydrationState.running);
          expect(export!.confirmed, isTrue);
        });
      });
    });

    test('waits for a running pass before reading', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      rows(const []);
      final status = registerStatus()..started();

      final pending = exporter.export(server);
      await pumpEventQueue();
      expect(calls, isEmpty);

      status.finished(CollectionHydrateOutcome.complete);
      final export = await pending;

      expect(calls, ['read']);
      expect(export!.confirmed, isTrue);
    });

    test('refresh runs the refresher first', () async {
      container.registerSingleton<GameCollectionRepository>(repository);
      rows(const []);
      container.registerSingleton<GameCollectionRefresher>(
        GameCollectionRefresher(() async => calls.add('refresh')),
      );

      await exporter.export(server, refresh: true);
      expect(calls, ['refresh', 'read']);

      calls.clear();
      await exporter.export(server);
      expect(calls, ['read']);
    });

    group('a last pass older than the window', () {
      late DateTime clock;
      late GameCollectionHydrationStatus status;

      setUp(() {
        container.registerSingleton<GameCollectionRepository>(repository);
        rows(const []);
        clock = DateTime.utc(2026, 11, 15, 12);
        status = registerStatus(now: () => clock)
          ..started()
          ..finished(CollectionHydrateOutcome.complete);
        clock = clock.add(GameCollectionHydrateInstaller.staleAfter);
      });

      void refresher(CollectionHydrateOutcome outcome) {
        container.registerSingleton<GameCollectionRefresher>(
          GameCollectionRefresher(() async {
            calls.add('refresh');
            status
              ..started()
              ..finished(outcome);
          }),
        );
      }

      test('is refreshed first, and a pass that lands confirms', () async {
        refresher(CollectionHydrateOutcome.complete);

        final export = await exporter.export(server);

        expect(calls, ['refresh', 'read']);
        expect(export!.confirmed, isTrue);
      });

      test('a refresh that fails leaves it unconfirmed', () async {
        refresher(CollectionHydrateOutcome.failed);

        final export = await exporter.export(server);

        expect(calls, ['refresh', 'read']);
        expect(export!.confirmed, isFalse);
      });

      test('with no refresher, is unconfirmed', () async {
        final export = await exporter.export(server);

        expect(calls, ['read']);
        expect(export!.confirmed, isFalse);
      });

      test('one just inside the window is neither refreshed nor '
          'unconfirmed', () async {
        refresher(CollectionHydrateOutcome.complete);
        clock = clock.subtract(const Duration(seconds: 1));

        final export = await exporter.export(server);

        expect(calls, ['read']);
        expect(export!.confirmed, isTrue);
      });
    });

    group('the wait for a pass ends after passWait', () {
      const short = GameCollectionExporter(
        passWait: Duration(milliseconds: 20),
      );

      setUp(() {
        container.registerSingleton<GameCollectionRepository>(repository);
        rows(const []);
      });

      test(
        'a running pass that does not finish leaves it unconfirmed',
        () async {
          registerStatus().started();

          final export = await short.export(server);

          expect(calls, ['read']);
          expect(export!.confirmed, isFalse);
        },
        timeout: const Timeout(Duration(seconds: 2)),
      );

      test(
        'a refresh that does not finish leaves it unconfirmed',
        () async {
          final status = registerStatus()
            ..finished(CollectionHydrateOutcome.complete);
          final never = Completer<void>();
          container.registerSingleton<GameCollectionRefresher>(
            GameCollectionRefresher(() {
              status.started();
              return never.future;
            }),
          );

          final export = await short.export(server, refresh: true);

          expect(calls, ['read']);
          expect(export!.confirmed, isFalse);
        },
        timeout: const Timeout(Duration(seconds: 2)),
      );

      test(
        'a pass given up on that lands during the read leaves it '
        'unconfirmed',
        () async {
          final status = registerStatus()..started();
          // The read the give-up starts outlasts the pass: the rows it
          // returns may predate what the pass lands.
          when(() => repository.watchCollectionListItems()).thenAnswer((_) {
            calls.add('read');
            status.finished(CollectionHydrateOutcome.complete);
            return Stream.value(const []);
          });

          final export = await short.export(server);

          expect(calls, ['read']);
          expect(status.state, HydrationState.refreshed);
          expect(export!.confirmed, isFalse);
        },
        timeout: const Timeout(Duration(seconds: 2)),
      );
    });

    test(
      'a status that closes while waiting does not hang',
      () async {
        container.registerSingleton<GameCollectionRepository>(repository);
        rows(const []);
        final status = GameCollectionHydrationStatus()..started();
        container.registerSingleton<GameCollectionHydrationStatus>(status);

        final pending = exporter.export(server);
        await pumpEventQueue();
        await status.close();

        final export = await pending;
        expect(export!.confirmed, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 2)),
    );

    test(
      'a repository whose stream closes without a value fails the export',
      () async {
        container.registerSingleton<GameCollectionRepository>(repository);
        when(
          () => repository.watchCollectionListItems(),
        ).thenAnswer((_) => const Stream.empty());

        await expectLater(exporter.export(server), throwsStateError);
      },
    );
  });
}
