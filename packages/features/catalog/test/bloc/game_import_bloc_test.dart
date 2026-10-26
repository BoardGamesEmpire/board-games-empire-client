import 'dart:async';
import 'dart:collection';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_games_remote.dart';

/// The batch every scripted start queues.
const _batchId = '0b7c2f9e-3a41-4c8e-9d2a-5f6b7c8d9e0f';

/// A poll's answer whose base game's job is [status].
///
/// [before] lists jobs ahead of the base game's, as an expansion's would be.
ImportBatch _batch(
  ImportJobStatus status, {
  String? gameId,
  ImportErrorCode? errorCode,
  ImportBatchStatus rollup = ImportBatchStatus.running,
  List<ImportJob> before = const [],
}) => ImportBatch(
  batchId: _batchId,
  correlationId: 'corr-1',
  status: rollup,
  jobs: [
    ...before,
    ImportJob(
      jobId: 'job_base',
      status: status,
      isExpansion: false,
      externalId: '926',
      gameId: gameId,
      errorCode: errorCode,
    ),
  ],
);

void main() {
  late FakeGamesRemote remote;

  setUp(() => remote = FakeGamesRemote());

  /// Every start is queued, as batch [_batchId].
  void queues() => remote.onStartImport = (_, _, correlationId) async =>
      GameImportReceipt(
        batchId: _batchId,
        baseJobId: 'job_base',
        correlationId: correlationId,
      );

  /// Answers each poll with the next of [answers]: a batch to return, or
  /// anything else to throw.
  void polls(List<Object> answers) {
    final queue = Queue.of(answers);
    remote.onFetchImport = (_) async => switch (queue.removeFirst()) {
      final ImportBatch batch => batch,
      final failure => throw failure,
    };
  }

  /// A bloc whose polls wait for nothing and run out after three, six
  /// seconds of two-second intervals, minting `corr-1`, `corr-2`, … as its
  /// correlation ids.
  GameImportBloc build({Future<void> Function(Duration)? wait}) {
    var minted = 0;
    return GameImportBloc(
      remote: remote,
      gatewayId: 'dg_bgg',
      externalId: '926',
      newCorrelationId: () => 'corr-${++minted}',
      wait: wait ?? (_) async {},
      deadline: const Duration(seconds: 6),
    );
  }

  const started = 'startImport(dg_bgg/926 corr-1)';
  const startedAgain = 'startImport(dg_bgg/926 corr-2)';
  const polled = 'fetchImport($_batchId)';

  // The first emit lands even though it equals the initial state: a bloc
  // drops a repeat only once it has emitted something.
  blocTest<GameImportBloc, GameImportState>(
    'imports, polls, and completes with the game',
    setUp: () {
      queues();
      polls([
        _batch(ImportJobStatus.pending),
        _batch(ImportJobStatus.running),
        _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportInProgress(running: true),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'the base job decides, not the batch',
    setUp: () {
      queues();
      polls([
        _batch(
          ImportJobStatus.completed,
          gameId: 'g_seafarers',
          rollup: ImportBatchStatus.partiallyCompleted,
          before: const [
            ImportJob(
              jobId: 'job_expansion',
              status: ImportJobStatus.failed,
              isExpansion: true,
              externalId: '927',
              errorCode: ImportErrorCode.gatewayError,
            ),
          ],
        ),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
  );

  group('a failed base job fails by its error code', () {
    for (final (code, failure) in [
      (ImportErrorCode.notFound, GameImportFailure.notOnDataGateway),
      (ImportErrorCode.gatewayError, GameImportFailure.dataGateway),
      (ImportErrorCode.internalError, GameImportFailure.server),
      (ImportErrorCode.baseImportFailed, GameImportFailure.server),
      (ImportErrorCode.unknown, GameImportFailure.server),
      (null, GameImportFailure.server),
    ]) {
      blocTest<GameImportBloc, GameImportState>(
        '${code?.name ?? 'no code'} is ${failure.name}',
        setUp: () {
          queues();
          polls([
            _batch(
              ImportJobStatus.failed,
              errorCode: code,
              rollup: ImportBatchStatus.failed,
            ),
          ]);
        },
        build: build,
        act: (bloc) => bloc.add(const GameImportRequested()),
        expect: () => [
          const GameImportStarting(),
          const GameImportInProgress(running: false),
          GameImportFailed(failure: failure),
        ],
      );
    }

    blocTest<GameImportBloc, GameImportState>(
      'a cancelled base job is cancelled',
      setUp: () {
        queues();
        polls([
          _batch(
            ImportJobStatus.cancelled,
            rollup: ImportBatchStatus.cancelled,
          ),
        ]);
      },
      build: build,
      act: (bloc) => bloc.add(const GameImportRequested()),
      expect: () => const [
        GameImportStarting(),
        GameImportInProgress(running: false),
        GameImportFailed(failure: GameImportFailure.cancelled),
      ],
    );
  });

  blocTest<GameImportBloc, GameImportState>(
    'a completed base job without a game id is a server failure',
    setUp: () {
      queues();
      polls([
        _batch(ImportJobStatus.completed, rollup: ImportBatchStatus.completed),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportFailed(failure: GameImportFailure.server),
    ],
  );

  blocTest<GameImportBloc, GameImportState>(
    'a poll with no answer keeps polling',
    setUp: () {
      queues();
      polls([
        unreachable(),
        _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'an unknown status keeps polling until the deadline',
    setUp: () {
      queues();
      polls([for (var i = 0; i < 3; i++) _batch(ImportJobStatus.unknown)]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportInProgress(running: true),
      GameImportStillRunning(),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'an unknown import ends it',
    setUp: () {
      queues();
      polls([const GameImportNotFoundException('404')]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportFailed(failure: GameImportFailure.server),
    ],
  );

  blocTest<GameImportBloc, GameImportState>(
    'a refused poll ends it as forbidden',
    setUp: () {
      queues();
      polls([const GamesForbiddenException('403')]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportFailed(failure: GameImportFailure.forbidden),
    ],
  );

  blocTest<GameImportBloc, GameImportState>(
    'checking again polls the same batch and sends no new import',
    setUp: () {
      queues();
      polls([
        for (var i = 0; i < 3; i++) _batch(ImportJobStatus.running),
        _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
      ]);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameImportRequested());
      await pumpEventQueue();
      bloc.add(const GameImportCheckAgainRequested());
    },
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportInProgress(running: true),
      GameImportStillRunning(),
      GameImportInProgress(running: true),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) =>
        expect(remote.calls, [started, polled, polled, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'once the deadline has passed, only checking again acts',
    setUp: () {
      queues();
      polls([for (var i = 0; i < 3; i++) _batch(ImportJobStatus.running)]);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameImportRequested());
      await pumpEventQueue();
      bloc.add(const GameImportRequested());
    },
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportInProgress(running: true),
      GameImportStillRunning(),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'once the import has completed, nothing acts',
    setUp: () {
      queues();
      polls([_batch(ImportJobStatus.completed, gameId: 'g_seafarers')]);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameImportRequested());
      await pumpEventQueue();
      bloc
        ..add(const GameImportRequested())
        ..add(const GameImportCheckAgainRequested());
    },
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) => expect(remote.calls, [started, polled]),
  );

  // A poll that waits out its timeouts takes far longer than its interval,
  // and the deadline is a time, not a count of polls.
  blocTest<GameImportBloc, GameImportState>(
    'a slow poll counts toward the deadline',
    setUp: () {
      queues();
      remote.onFetchImport = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw const GamesRemoteTransientException('timed out');
      };
    },
    build: () => GameImportBloc(
      remote: remote,
      gatewayId: 'dg_bgg',
      externalId: '926',
      newCorrelationId: () => 'corr-1',
      wait: (_) async {},
      pollInterval: const Duration(milliseconds: 10),
      deadline: const Duration(milliseconds: 30),
    ),
    act: (bloc) => bloc.add(const GameImportRequested()),
    wait: const Duration(milliseconds: 200),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportStillRunning(),
    ],
    verify: (_) => expect(remote.calls, [started, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'trying again after no answer re-sends the same correlation id',
    setUp: () {
      var starts = 0;
      remote.onStartImport = (_, _, correlationId) async {
        // The first start's answer is lost; the server may have queued it.
        if (starts++ == 0) throw unreachable();
        return GameImportReceipt(
          batchId: _batchId,
          baseJobId: 'job_base',
          correlationId: correlationId,
        );
      };
      polls([_batch(ImportJobStatus.completed, gameId: 'g_seafarers')]);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameImportRequested());
      await pumpEventQueue();
      bloc.add(const GameImportRequested());
    },
    expect: () => const [
      GameImportStarting(),
      GameImportFailed(failure: GameImportFailure.unreachable),
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) => expect(remote.calls, [started, started, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'trying again after a failed import sends a new correlation id',
    setUp: () {
      queues();
      polls([
        _batch(ImportJobStatus.failed, errorCode: ImportErrorCode.gatewayError),
        _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
      ]);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameImportRequested());
      await pumpEventQueue();
      bloc.add(const GameImportRequested());
    },
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportFailed(failure: GameImportFailure.dataGateway),
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) =>
        expect(remote.calls, [started, polled, startedAgain, polled]),
  );

  group('a refused start drops the correlation id', () {
    for (final (refusal, failure) in [
      (const GamesForbiddenException('403'), GameImportFailure.forbidden),
      (const GamesRemotePermanentException('400'), GameImportFailure.server),
    ]) {
      blocTest<GameImportBloc, GameImportState>(
        '${refusal.runtimeType} is ${failure.name}',
        setUp: () => remote.onStartImport = (_, _, _) async => throw refusal,
        build: build,
        act: (bloc) async {
          bloc.add(const GameImportRequested());
          await pumpEventQueue();
          bloc.add(const GameImportRequested());
        },
        expect: () => [
          const GameImportStarting(),
          GameImportFailed(failure: failure),
          const GameImportStarting(),
          GameImportFailed(failure: failure),
        ],
        verify: (_) => expect(remote.calls, [started, startedAgain]),
      );
    }
  });

  test('closing stops the polling', () async {
    queues();
    polls([_batch(ImportJobStatus.running)]);
    final waiting = Completer<void>();
    final bloc = build(wait: (_) => waiting.future);
    final states = <GameImportState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);

    bloc.add(const GameImportRequested());
    await pumpEventQueue();
    expect(bloc.state, const GameImportInProgress(running: false));

    await bloc.close();
    waiting.complete();
    await pumpEventQueue();

    expect(remote.calls, [started]);
    expect(states, const [
      GameImportStarting(),
      GameImportInProgress(running: false),
    ]);
  });

  blocTest<GameImportBloc, GameImportState>(
    'a request while importing is dropped',
    setUp: () {
      queues();
      polls([_batch(ImportJobStatus.completed, gameId: 'g_seafarers')]);
    },
    build: build,
    act: (bloc) => bloc
      ..add(const GameImportRequested())
      ..add(const GameImportRequested()),
    expect: () => const [
      GameImportStarting(),
      GameImportInProgress(running: false),
      GameImportCompleted(gameId: 'g_seafarers'),
    ],
    verify: (_) => expect(remote.calls, [started, polled]),
  );
}
