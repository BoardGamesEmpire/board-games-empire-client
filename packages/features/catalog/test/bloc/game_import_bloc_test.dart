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

/// The batch a second start queues, where a test tells them apart.
const _secondBatchId = '7e1d4a2b-9c3f-4b6e-8a5d-2f1e0c9b8a7d';

/// The requested game's job, [status] as given.
ImportJob _req(
  ImportJobStatus status, {
  String? gameId,
  ImportErrorCode? errorCode,
}) => ImportJob(
  jobId: 'job_base',
  status: status,
  origin: ImportJobOrigin.requested,
  externalId: '926',
  gameId: gameId,
  errorCode: errorCode,
);

/// A job chosen with the requested game, or added for it.
ImportJob _other(
  ImportJobStatus status, {
  String id = 'job_exp',
  String externalId = '21',
  ImportJobOrigin origin = ImportJobOrigin.chosenExpansion,
  String? gameId,
  ImportErrorCode? errorCode,
}) => ImportJob(
  jobId: id,
  status: status,
  origin: origin,
  parentJobId: 'job_base',
  externalId: externalId,
  gameId: gameId,
  errorCode: errorCode,
);

/// A poll's answer listing [jobs], the requested game's first.
ImportBatch _batchOf(
  List<ImportJob> jobs, {
  ImportBatchStatus rollup = ImportBatchStatus.running,
}) => ImportBatch(
  batchId: _batchId,
  correlationId: 'corr-1',
  status: rollup,
  jobs: jobs,
);

/// A poll's answer whose only job is the requested game's, [status].
ImportBatch _batch(
  ImportJobStatus status, {
  String? gameId,
  ImportErrorCode? errorCode,
  ImportBatchStatus rollup = ImportBatchStatus.running,
}) => _batchOf([
  _req(status, gameId: gameId, errorCode: errorCode),
], rollup: rollup);

void main() {
  late FakeGamesRemote remote;

  setUp(() => remote = FakeGamesRemote());

  /// Every start is queued: the first as batch [_batchId], and each after it
  /// as the next of [later], or as [_batchId] again once they run out.
  void queues({List<String> later = const []}) {
    final next = Queue.of([_batchId, ...later]);
    remote.onStartImport = (_, _, correlationId) async => GameImportReceipt(
      batchId: next.length > 1 ? next.removeFirst() : next.first,
      baseJobId: 'job_base',
      correlationId: correlationId,
    );
  }

  /// Answers each poll with the next of [answers]: a batch to return, or
  /// an [Exception] to throw.
  void polls(List<Object> answers) {
    final queue = Queue.of(answers);
    remote.onFetchImport = (_) async => switch (queue.removeFirst()) {
      final ImportBatch batch => batch,
      final Exception failure => throw failure,
      final other => throw StateError(
        'polls answers a batch or an Exception: $other',
      ),
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
      baseDeadline: const Duration(seconds: 6),
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
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: false,
        jobs: [_req(ImportJobStatus.pending)],
      ),
      GameImportInProgress(
        running: true,
        jobs: [_req(ImportJobStatus.running)],
      ),
      GameImportCompleted(
        gameId: 'g_seafarers',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'sends the chosen expansions',
    setUp: () {
      queues();
      polls([_batch(ImportJobStatus.completed, gameId: 'g_seafarers')]);
    },
    build: () => GameImportBloc(
      remote: remote,
      gatewayId: 'dg_bgg',
      externalId: '926',
      expansionExternalIds: const ['21'],
      newCorrelationId: () => 'corr-1',
      wait: (_) async {},
    ),
    act: (bloc) => bloc.add(const GameImportRequested()),
    verify: (_) => expect(remote.importedExpansions, [
      ['21'],
    ]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'waits for a chosen expansion after the requested game completes',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(ImportJobStatus.completed, gameId: 'g1'),
          _other(ImportJobStatus.running),
        ]),
        _batchOf([
          _req(ImportJobStatus.completed, gameId: 'g1'),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: true,
        jobs: [
          _req(ImportJobStatus.completed, gameId: 'g1'),
          _other(ImportJobStatus.running),
        ],
      ),
      GameImportCompleted(
        gameId: 'g1',
        jobs: [
          _req(ImportJobStatus.completed, gameId: 'g1'),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'a pending requested job reads as not yet running',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(ImportJobStatus.pending),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ]),
        _batch(ImportJobStatus.completed, gameId: 'g1'),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: false,
        jobs: [
          _req(ImportJobStatus.pending),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ],
      ),
      GameImportCompleted(
        gameId: 'g1',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g1')],
      ),
    ],
  );

  blocTest<GameImportBloc, GameImportState>(
    'a chosen expansion that fails leaves the import partly completed',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(ImportJobStatus.completed, gameId: 'g1'),
          _other(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.gatewayError,
          ),
        ], rollup: ImportBatchStatus.partiallyCompleted),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportPartlyCompleted(
        gameId: 'g1',
        jobs: [
          _req(ImportJobStatus.completed, gameId: 'g1'),
          _other(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.gatewayError,
          ),
        ],
      ),
    ],
  );

  blocTest<GameImportBloc, GameImportState>(
    'an added base game that fails leaves the import partly completed',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _other(
            ImportJobStatus.failed,
            id: 'job_base_game',
            externalId: '13',
            origin: ImportJobOrigin.addedBaseGame,
            errorCode: ImportErrorCode.gatewayError,
          ),
          _req(ImportJobStatus.completed, gameId: 'g1'),
        ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportPartlyCompleted(
        gameId: 'g1',
        jobs: [
          _other(
            ImportJobStatus.failed,
            id: 'job_base_game',
            externalId: '13',
            origin: ImportJobOrigin.addedBaseGame,
            errorCode: ImportErrorCode.gatewayError,
          ),
          _req(ImportJobStatus.completed, gameId: 'g1'),
        ],
      ),
    ],
  );

  blocTest<GameImportBloc, GameImportState>(
    'a failed requested game with no other job open ends the import at once',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.notFound,
          ),
          _other(
            ImportJobStatus.cancelled,
            errorCode: ImportErrorCode.baseImportFailed,
          ),
        ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportFailed(
        failure: GameImportFailure.notOnDataGateway,
        jobs: [
          _req(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.notFound,
          ),
          _other(
            ImportJobStatus.cancelled,
            errorCode: ImportErrorCode.baseImportFailed,
          ),
        ],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled]),
  );

  // The server cancels only a pending job of a failed one; a running job
  // goes on, and the rows would freeze at a state the server then left
  // (#824).
  blocTest<GameImportBloc, GameImportState>(
    'a failed requested game waits for the jobs still open',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.notFound,
          ),
          _other(ImportJobStatus.pending),
        ]),
        _batchOf([
          _req(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.notFound,
          ),
          _other(
            ImportJobStatus.cancelled,
            errorCode: ImportErrorCode.baseImportFailed,
          ),
        ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: true,
        jobs: [
          _req(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.notFound,
          ),
          _other(ImportJobStatus.pending),
        ],
      ),
      GameImportFailed(
        failure: GameImportFailure.notOnDataGateway,
        jobs: [
          _req(
            ImportJobStatus.failed,
            errorCode: ImportErrorCode.notFound,
          ),
          _other(
            ImportJobStatus.cancelled,
            errorCode: ImportErrorCode.baseImportFailed,
          ),
        ],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled]),
  );

  // The requested game's outcome is known, so it is not still running.
  blocTest<GameImportBloc, GameImportState>(
    'a failed requested game ends as failed once the deadline passes',
    setUp: () {
      queues();
      polls([
        for (var i = 0; i < 40; i++)
          _batchOf([
            _req(
              ImportJobStatus.failed,
              errorCode: ImportErrorCode.gatewayError,
            ),
            _other(ImportJobStatus.running),
          ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () {
      final jobs = [
        _req(ImportJobStatus.failed, errorCode: ImportErrorCode.gatewayError),
        _other(ImportJobStatus.running),
      ];
      return [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        GameImportInProgress(running: true, jobs: jobs),
        GameImportFailed(failure: GameImportFailure.dataGateway, jobs: jobs),
      ];
    },
    // Two jobs: 6 s and 30 more, of two-second waits.
    verify: (_) => expect(
      remote.calls.where((call) => call == polled).length,
      18,
    ),
  );

  // The first batch's other job still runs on the server. The second batch
  // may import the same games, which the server makes one game of.
  blocTest<GameImportBloc, GameImportState>(
    'trying again after a failure at the deadline queues a second batch',
    setUp: () {
      queues(later: [_secondBatchId]);
      polls([
        for (var i = 0; i < 18; i++)
          _batchOf([
            _req(
              ImportJobStatus.failed,
              errorCode: ImportErrorCode.gatewayError,
            ),
            _other(ImportJobStatus.running),
          ]),
        _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
      ]);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameImportRequested());
      await pumpEventQueue();
      bloc.add(const GameImportRequested());
    },
    verify: (bloc) {
      expect(
        bloc.state,
        GameImportCompleted(
          gameId: 'g_seafarers',
          jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
        ),
      );
      // The second batch is the one followed now.
      expect(remote.calls, [
        started,
        for (var i = 0; i < 18; i++) polled,
        startedAgain,
        'fetchImport($_secondBatchId)',
      ]);
    },
  );

  // The game is on the server, so it can be opened while the others run on.
  blocTest<GameImportBloc, GameImportState>(
    'a completed requested game still running at the deadline carries its id',
    setUp: () {
      queues();
      polls([
        for (var i = 0; i < 18; i++)
          _batchOf([
            _req(ImportJobStatus.completed, gameId: 'g_seafarers'),
            _other(ImportJobStatus.running),
          ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () {
      final jobs = [
        _req(ImportJobStatus.completed, gameId: 'g_seafarers'),
        _other(ImportJobStatus.running),
      ];
      return [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        GameImportInProgress(running: true, jobs: jobs),
        GameImportStillRunning(gameId: 'g_seafarers', jobs: jobs),
      ];
    },
  );

  // As the batch's end judges it: the game can't be opened without its id.
  blocTest<GameImportBloc, GameImportState>(
    'a completed requested job without a game id at the deadline fails',
    setUp: () {
      queues();
      polls([
        for (var i = 0; i < 18; i++)
          _batchOf([
            _req(ImportJobStatus.completed),
            _other(ImportJobStatus.running),
          ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    verify: (bloc) => expect(
      bloc.state,
      GameImportFailed(
        failure: GameImportFailure.server,
        jobs: [
          _req(ImportJobStatus.completed),
          _other(ImportJobStatus.running),
        ],
      ),
    ),
  );

  blocTest<GameImportBloc, GameImportState>(
    'a completed requested job without a game id waits for the others',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(ImportJobStatus.completed),
          _other(ImportJobStatus.running),
        ]),
        _batchOf([
          _req(ImportJobStatus.completed),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: true,
        jobs: [
          _req(ImportJobStatus.completed),
          _other(ImportJobStatus.running),
        ],
      ),
      GameImportFailed(
        failure: GameImportFailure.server,
        jobs: [
          _req(ImportJobStatus.completed),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled]),
  );

  blocTest<GameImportBloc, GameImportState>(
    'a cancelled requested game waits for a running job, then is cancelled',
    setUp: () {
      queues();
      polls([
        _batchOf([
          _req(ImportJobStatus.cancelled),
          _other(ImportJobStatus.running),
        ]),
        _batchOf([
          _req(ImportJobStatus.cancelled),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ]),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: true,
        jobs: [
          _req(ImportJobStatus.cancelled),
          _other(ImportJobStatus.running),
        ],
      ),
      GameImportFailed(
        failure: GameImportFailure.cancelled,
        jobs: [
          _req(ImportJobStatus.cancelled),
          _other(ImportJobStatus.completed, gameId: 'g2'),
        ],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled]),
  );

  group('a failed requested job fails by its error code', () {
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
          GameImportFailed(
            failure: failure,
            jobs: [_req(ImportJobStatus.failed, errorCode: code)],
          ),
        ],
      );
    }

    blocTest<GameImportBloc, GameImportState>(
      'a cancelled requested job is cancelled',
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
      expect: () => [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        GameImportFailed(
          failure: GameImportFailure.cancelled,
          jobs: [_req(ImportJobStatus.cancelled)],
        ),
      ],
    );
  });

  blocTest<GameImportBloc, GameImportState>(
    'a completed requested job without a game id is a server failure',
    setUp: () {
      queues();
      polls([
        _batch(ImportJobStatus.completed, rollup: ImportBatchStatus.completed),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportFailed(
        failure: GameImportFailure.server,
        jobs: [_req(ImportJobStatus.completed)],
      ),
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
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportCompleted(
        gameId: 'g_seafarers',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
      ),
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
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: true,
        jobs: [_req(ImportJobStatus.unknown)],
      ),
      GameImportStillRunning(jobs: [_req(ImportJobStatus.unknown)]),
    ],
    verify: (_) => expect(remote.calls, [started, polled, polled, polled]),
  );

  // That a completed game still doesn't end the import shows the bloc never
  // followed it.
  blocTest<GameImportBloc, GameImportState>(
    'a batch with no requested job keeps polling until the deadline',
    setUp: () {
      queues();
      polls([
        for (var i = 0; i < 3; i++)
          _batchOf([
            _other(
              ImportJobStatus.completed,
              id: 'job_base',
              externalId: '926',
              origin: ImportJobOrigin.unknown,
              gameId: 'g_seafarers',
            ),
          ], rollup: ImportBatchStatus.completed),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () {
      final jobs = [
        _other(
          ImportJobStatus.completed,
          id: 'job_base',
          externalId: '926',
          origin: ImportJobOrigin.unknown,
          gameId: 'g_seafarers',
        ),
      ];
      return [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        GameImportInProgress(running: true, jobs: jobs),
        GameImportStillRunning(jobs: jobs),
      ];
    },
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
    "a refused poll after an answer keeps the last poll's jobs",
    setUp: () {
      queues();
      polls([
        _batch(ImportJobStatus.running),
        const GamesForbiddenException('403'),
      ]);
    },
    build: build,
    act: (bloc) => bloc.add(const GameImportRequested()),
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportInProgress(
        running: true,
        jobs: [_req(ImportJobStatus.running)],
      ),
      GameImportFailed(
        failure: GameImportFailure.forbidden,
        jobs: [_req(ImportJobStatus.running)],
      ),
    ],
  );

  // A poll that fails says nothing of a game an earlier poll saw imported.
  group('a failed poll after the requested game completed', () {
    final running = [
      _req(ImportJobStatus.completed, gameId: 'g1'),
      _other(ImportJobStatus.running),
    ];
    final done = [
      _req(ImportJobStatus.completed, gameId: 'g1'),
      _other(ImportJobStatus.completed, gameId: 'g2'),
    ];

    for (final failure in [
      const GamesForbiddenException('403'),
      const GamesRemotePermanentException('500'),
      const GameImportNotFoundException('404'),
    ]) {
      blocTest<GameImportBloc, GameImportState>(
        '${failure.runtimeType} keeps the game, and checking again polls '
        'the same batch',
        setUp: () {
          queues();
          polls([_batchOf(running), failure, _batchOf(done)]);
        },
        build: build,
        act: (bloc) async {
          bloc.add(const GameImportRequested());
          await pumpEventQueue();
          bloc.add(const GameImportCheckAgainRequested());
        },
        expect: () => [
          const GameImportStarting(),
          const GameImportInProgress(running: false),
          GameImportInProgress(running: true, jobs: running),
          GameImportStillRunning(gameId: 'g1', jobs: running),
          GameImportInProgress(running: true, jobs: running),
          GameImportCompleted(gameId: 'g1', jobs: done),
        ],
        verify: (_) => expect(remote.calls, [started, polled, polled, polled]),
      );
    }
  });

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
    expect: () {
      final running = [_req(ImportJobStatus.running)];
      return [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        GameImportInProgress(running: true, jobs: running),
        GameImportStillRunning(jobs: running),
        GameImportInProgress(running: true, jobs: running),
        GameImportCompleted(
          gameId: 'g_seafarers',
          jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
        ),
      ];
    },
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
    expect: () {
      final running = [_req(ImportJobStatus.running)];
      return [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        GameImportInProgress(running: true, jobs: running),
        GameImportStillRunning(jobs: running),
      ];
    },
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
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportCompleted(
        gameId: 'g_seafarers',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled]),
  );

  test('deadlineFor grows 30 seconds a job, to 10 minutes', () {
    expect(GameImportBloc.deadlineFor(1), const Duration(seconds: 90));
    expect(GameImportBloc.deadlineFor(3), const Duration(seconds: 150));
    expect(GameImportBloc.deadlineFor(100), const Duration(minutes: 10));
    expect(
      GameImportBloc.deadlineFor(3, base: const Duration(seconds: 4)),
      const Duration(seconds: 64),
    );
  });

  // A one-job batch runs out after two polls here, so a third poll can only
  // come from the deadline having grown with the three jobs.
  blocTest<GameImportBloc, GameImportState>(
    'the deadline grows with the batch',
    setUp: () {
      queues();
      polls([
        for (var i = 0; i < 40; i++)
          _batchOf([
            _req(ImportJobStatus.running),
            _other(ImportJobStatus.running, id: 'job_a'),
            _other(ImportJobStatus.running, id: 'job_b'),
          ]),
      ]);
    },
    build: () => GameImportBloc(
      remote: remote,
      gatewayId: 'dg_bgg',
      externalId: '926',
      newCorrelationId: () => 'corr-1',
      wait: (_) async {},
      baseDeadline: const Duration(seconds: 4),
    ),
    act: (bloc) => bloc.add(const GameImportRequested()),
    verify: (bloc) {
      final polls = remote.calls.where((call) => call == polled).length;
      // 64 s of two-second waits.
      expect(polls, 32);
      expect(bloc.state, isA<GameImportStillRunning>());
    },
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
      baseDeadline: const Duration(milliseconds: 30),
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
    expect: () => [
      const GameImportStarting(),
      const GameImportFailed(failure: GameImportFailure.unreachable),
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportCompleted(
        gameId: 'g_seafarers',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
      ),
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
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportFailed(
        failure: GameImportFailure.dataGateway,
        jobs: [
          _req(ImportJobStatus.failed, errorCode: ImportErrorCode.gatewayError),
        ],
      ),
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportCompleted(
        gameId: 'g_seafarers',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
      ),
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
    expect: () => [
      const GameImportStarting(),
      const GameImportInProgress(running: false),
      GameImportCompleted(
        gameId: 'g_seafarers',
        jobs: [_req(ImportJobStatus.completed, gameId: 'g_seafarers')],
      ),
    ],
    verify: (_) => expect(remote.calls, [started, polled]),
  );
}
