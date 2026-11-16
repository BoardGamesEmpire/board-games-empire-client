import 'dart:async';
import 'dart:typed_data';

import 'package:bge_test_support/domain.dart';
import 'package:data_export/data_export.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:mocktail/mocktail.dart';
import 'package:observability/observability.dart';

/// The bundler's `assemble`, as the cubit takes it.
abstract class _Assemble {
  Future<UserDataExportBundle> call(
    ActiveServer server, {
    bool refresh = false,
  });
}

class _MockAssemble extends Mock implements _Assemble {}

class _MockSink extends Mock implements UserDataExportSink {}

class _MockContainer extends Mock implements DependencyContainer {}

class _MockLogger extends Mock implements BgeLogger {}

const Duration _dwell = DataExportCubit.answerDwell;
const _ms = Duration(milliseconds: 1);

UserDataExportBundle _bundle({
  List<String> unconfirmed = const [],
  String exportedAt = '2026-11-15T12:00:00.000Z',
}) => UserDataExportBundle(
  json: {
    'schemaVersion': 1,
    'exportedAt': exportedAt,
    'serverName': 'Test BGE Server',
    'categories': <String, Object?>{},
  },
  unconfirmedKeys: unconfirmed,
);

DataExportState _state(
  DataExportPhase phase, {
  List<String> keys = const [],
  DataExportRun? run,
  bool underWarning = false,
  DataExportFailure? failure,
  int answers = 0,
}) => DataExportState(
  phase: phase,
  unconfirmedKeys: keys,
  run: run,
  runUnderWarning: underWarning,
  failure: failure,
  answers: answers,
);

void main() {
  late _MockAssemble assemble;
  late _MockSink sink;
  late _MockLogger logger;
  late ActiveServer server;

  setUpAll(() {
    registerFallbackValue(
      ActiveServer(
        serverId: 'fallback',
        displayName: 'Fallback',
        identity: testServerIdentity(),
        container: _MockContainer(),
      ),
    );
    registerFallbackValue(Uint8List(0));
  });

  setUp(() {
    assemble = _MockAssemble();
    sink = _MockSink();
    logger = _MockLogger();
    server = ActiveServer(
      serverId: 'local-1',
      displayName: 'My nickname for it',
      identity: testServerIdentity(),
      container: _MockContainer(),
    );
  });

  void assembles(Future<UserDataExportBundle> Function() answer) => when(
    () => assemble(any(), refresh: any(named: 'refresh')),
  ).thenAnswer((_) => answer());

  void saves(Future<UserDataExportSaveResult> Function() answer) => when(
    () => sink.save(
      fileName: any(named: 'fileName'),
      bytes: any(named: 'bytes'),
    ),
  ).thenAnswer((_) => answer());

  /// Runs [body] under a fake clock with a fresh cubit and the states it
  /// emits from then on, then closes the cubit.
  void run(
    void Function(
      FakeAsync async,
      DataExportCubit cubit,
      List<DataExportState> states,
    )
    body,
  ) {
    fakeAsync((async) {
      final cubit = DataExportCubit(
        server: server,
        assemble: assemble.call,
        sink: sink,
        logger: logger,
      );
      final states = <DataExportState>[];
      cubit.stream.listen(states.add);
      body(async, cubit, states);
      unawaited(cubit.close());
      async.flushMicrotasks();
    });
  }

  /// Takes [cubit] to the warning, holding a bundle whose collection is
  /// unconfirmed, and forgets the states on the way.
  void toWarning(
    FakeAsync async,
    DataExportCubit cubit,
    List<DataExportState> states,
  ) {
    assembles(() async => _bundle(unconfirmed: ['gameCollection']));
    cubit.export();
    async.elapse(_dwell);
    expect(
      cubit.state,
      _state(
        DataExportPhase.unconfirmed,
        keys: ['gameCollection'],
        answers: 1,
      ),
    );
    states.clear();
  }

  test('starts ready, with no warning, no failure and no answer', () {
    run((async, cubit, states) {
      expect(cubit.state, _state(DataExportPhase.ready));
    });
  });

  test('a confirmed bundle saves straight away', () {
    run((async, cubit, states) {
      final bundle = _bundle();
      assembles(() async => bundle);
      saves(() async => UserDataExportSaveResult.saved);

      cubit.export();
      async.flushMicrotasks();
      // The save dialog opens at once: no dwell before saving.
      expect(states, [
        _state(DataExportPhase.assembling, run: DataExportRun.export),
        _state(DataExportPhase.saving, run: DataExportRun.export),
      ]);

      async.elapse(_dwell);
      expect(states, [
        _state(DataExportPhase.assembling, run: DataExportRun.export),
        _state(DataExportPhase.saving, run: DataExportRun.export),
        _state(DataExportPhase.saved, answers: 1),
      ]);
      verify(() => assemble(server)).called(1);
      verify(
        () => sink.save(fileName: bundle.fileName, bytes: bundle.toBytes()),
      ).called(1);
    });
  });

  test('a web sink reports downloaded', () {
    run((async, cubit, states) {
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);

      cubit.export();
      async.elapse(_dwell);

      expect(states.last, _state(DataExportPhase.downloaded, answers: 1));
    });
  });

  test('a cancelled save returns to ready with no outcome', () {
    run((async, cubit, states) {
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.cancelled);

      cubit.export();
      async.flushMicrotasks();

      // A cancel is no answer: it waits for nothing and counts nothing.
      expect(states, [
        _state(DataExportPhase.assembling, run: DataExportRun.export),
        _state(DataExportPhase.saving, run: DataExportRun.export),
        _state(DataExportPhase.ready),
      ]);
    });
  });

  test('an unconfirmed bundle waits for a choice', () {
    run((async, cubit, states) {
      assembles(() async => _bundle(unconfirmed: ['gameCollection']));

      cubit.export();
      async.elapse(_dwell);

      expect(states, [
        _state(DataExportPhase.assembling, run: DataExportRun.export),
        _state(
          DataExportPhase.unconfirmed,
          keys: ['gameCollection'],
          answers: 1,
        ),
      ]);
      verifyNever(
        () => sink.save(
          fileName: any(named: 'fileName'),
          bytes: any(named: 'bytes'),
        ),
      );
    });
  });

  test('saveAnyway saves the held bundle', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      final held = _bundle(unconfirmed: ['gameCollection']);
      saves(() async => UserDataExportSaveResult.saved);

      cubit.saveAnyway();
      async.elapse(_dwell);

      expect(states, [
        // The warning stays up through its own action: the copy it describes
        // is the one being saved.
        _state(
          DataExportPhase.saving,
          keys: ['gameCollection'],
          run: DataExportRun.saveAnyway,
          underWarning: true,
          answers: 1,
        ),
        _state(DataExportPhase.saved, answers: 2),
      ]);
      verify(
        () => assemble(any(), refresh: any(named: 'refresh')),
      ).called(1);
      verify(
        () => sink.save(fileName: held.fileName, bytes: held.toBytes()),
      ).called(1);
    });
  });

  test('a cancelled "save this copy" returns to the warning with the bundle '
      'still held', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      saves(() async => UserDataExportSaveResult.cancelled);

      cubit.saveAnyway();
      async.flushMicrotasks();

      expect(states, [
        _state(
          DataExportPhase.saving,
          keys: ['gameCollection'],
          run: DataExportRun.saveAnyway,
          underWarning: true,
          answers: 1,
        ),
        _state(
          DataExportPhase.unconfirmed,
          keys: ['gameCollection'],
          answers: 1,
        ),
      ]);

      saves(() async => UserDataExportSaveResult.saved);
      cubit.saveAnyway();
      async.elapse(_dwell);

      expect(states.last, _state(DataExportPhase.saved, answers: 2));
      verify(
        () => assemble(any(), refresh: any(named: 'refresh')),
      ).called(1);
    });
  });

  test('a failed "save this copy" drops the warning', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      saves(() async => throw Exception('disk full'));

      cubit.saveAnyway();
      async.elapse(_dwell);
      expect(
        states.last,
        _state(
          DataExportPhase.failed,
          failure: DataExportFailure.saveFailed,
          answers: 2,
        ),
      );

      // The bundle went with the warning: nothing is left to save.
      cubit.saveAnyway();
      async.elapse(_dwell);
      verify(
        () => sink.save(
          fileName: any(named: 'fileName'),
          bytes: any(named: 'bytes'),
        ),
      ).called(1);
    });
  });

  test('refreshAndExport assembles with refresh: true', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);

      cubit.refreshAndExport();
      async.elapse(_dwell);

      verify(() => assemble(server, refresh: true)).called(1);
    });
  });

  test('the banner goes when a refresh confirms, and the buttons stay until '
      'the save lands', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.saved);

      cubit.refreshAndExport();
      async.elapse(_dwell);

      expect(states, [
        _state(
          DataExportPhase.assembling,
          keys: ['gameCollection'],
          run: DataExportRun.refreshAndExport,
          underWarning: true,
          answers: 1,
        ),
        // A newer copy, confirmed: the banner has nothing left to describe,
        // and the buttons stay until the run lands.
        _state(
          DataExportPhase.saving,
          run: DataExportRun.refreshAndExport,
          underWarning: true,
          answers: 1,
        ),
        _state(DataExportPhase.saved, answers: 2),
      ]);
      expect(states[1].showsWarningBanner, isFalse);
      expect(states[1].showsWarningButtons, isTrue);
      expect(states[2].showsWarningButtons, isFalse);
    });
  });

  test('a confirmed refresh whose save is cancelled returns to ready', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.cancelled);

      cubit.refreshAndExport();
      async.elapse(_dwell);
      expect(states.last, _state(DataExportPhase.ready, answers: 1));

      // The confirmed bundle went with the cancel: nothing is held.
      cubit.saveAnyway();
      async.elapse(_dwell);
      verify(
        () => sink.save(
          fileName: any(named: 'fileName'),
          bytes: any(named: 'bytes'),
        ),
      ).called(1);
    });
  });

  test('refreshAndExport keeps the warning up while it runs', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      final refreshed = Completer<UserDataExportBundle>();
      assembles(() => refreshed.future);

      cubit.refreshAndExport();
      async.elapse(_dwell * 2);

      expect(states, [
        _state(
          DataExportPhase.assembling,
          keys: ['gameCollection'],
          run: DataExportRun.refreshAndExport,
          underWarning: true,
          answers: 1,
        ),
      ]);
    });
  });

  test('a refresh that still cannot confirm lands on unconfirmed again', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);

      cubit.refreshAndExport();
      async.elapse(_dwell);

      expect(states, [
        _state(
          DataExportPhase.assembling,
          keys: ['gameCollection'],
          run: DataExportRun.refreshAndExport,
          underWarning: true,
          answers: 1,
        ),
        // The same warning, as a new answer.
        _state(
          DataExportPhase.unconfirmed,
          keys: ['gameCollection'],
          answers: 2,
        ),
      ]);
      verify(() => assemble(server, refresh: true)).called(1);
    });
  });

  test('"save this copy" after a refresh that still cannot confirm saves the '
      'refreshed bundle', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      final refreshed = _bundle(
        unconfirmed: ['gameCollection'],
        exportedAt: '2026-11-15T13:30:00.000Z',
      );
      assembles(() async => refreshed);
      saves(() async => UserDataExportSaveResult.saved);
      cubit.refreshAndExport();
      async.elapse(_dwell);
      states.clear();

      cubit.saveAnyway();
      async.elapse(_dwell);

      expect(states, [
        _state(
          DataExportPhase.saving,
          keys: ['gameCollection'],
          run: DataExportRun.saveAnyway,
          underWarning: true,
          answers: 2,
        ),
        _state(DataExportPhase.saved, answers: 3),
      ]);
      // Its bytes, not those of the bundle the first warning was about.
      expect(refreshed.toBytes(), isNot(_bundle().toBytes()));
      verify(
        () => sink.save(
          fileName: refreshed.fileName,
          bytes: refreshed.toBytes(),
        ),
      ).called(1);
    });
  });

  test('a refresh that fails drops the warning', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      assembles(() async => throw StateError('exporter broke'));

      cubit.refreshAndExport();
      async.elapse(_dwell);
      expect(
        states.last,
        _state(
          DataExportPhase.failed,
          failure: DataExportFailure.unexpected,
          answers: 2,
        ),
      );

      cubit.saveAnyway();
      async.elapse(_dwell);
      verifyNever(
        () => sink.save(
          fileName: any(named: 'fileName'),
          bytes: any(named: 'bytes'),
        ),
      );
    });
  });

  test('export from the warning keeps it up while it runs', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      assembles(() async => _bundle(unconfirmed: ['gameCollection']));

      cubit.export();
      async.elapse(_dwell);

      expect(states, [
        // The held copy is still the newest known, and the run began under
        // the warning.
        _state(
          DataExportPhase.assembling,
          keys: ['gameCollection'],
          run: DataExportRun.export,
          underWarning: true,
          answers: 1,
        ),
        _state(
          DataExportPhase.unconfirmed,
          keys: ['gameCollection'],
          answers: 2,
        ),
      ]);
      verify(() => assemble(server)).called(2);
    });
  });

  test('export from the warning, confirmed, drops the banner as it saves and '
      'the buttons as it lands', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.cancelled);

      cubit.export();
      async.elapse(_dwell);

      expect(states, [
        _state(
          DataExportPhase.assembling,
          keys: ['gameCollection'],
          run: DataExportRun.export,
          underWarning: true,
          answers: 1,
        ),
        _state(
          DataExportPhase.saving,
          run: DataExportRun.export,
          underWarning: true,
          answers: 1,
        ),
        _state(DataExportPhase.ready, answers: 1),
      ]);
    });
  });

  group('failures', () {
    test('no session fails as notAuthenticated', () {
      run((async, cubit, states) {
        assembles(() async => throw const ExportNotAuthenticatedException());

        cubit.export();
        async.elapse(_dwell);

        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
          _state(
            DataExportPhase.failed,
            failure: DataExportFailure.notAuthenticated,
            answers: 1,
          ),
        ]);
      });
    });

    test('a session that cannot be read fails as sessionUnavailable', () {
      run((async, cubit, states) {
        assembles(
          () async => throw ExportSessionUnavailableException(
            cause: Exception('secure store'),
          ),
        );

        cubit.export();
        async.elapse(_dwell);

        expect(
          states.last,
          _state(
            DataExportPhase.failed,
            failure: DataExportFailure.sessionUnavailable,
            answers: 1,
          ),
        );
      });
    });

    test('any other assemble error fails as unexpected, and is logged', () {
      run((async, cubit, states) {
        final error = StateError('exporter broke');
        assembles(() async => throw error);

        cubit.export();
        async.elapse(_dwell);

        expect(
          states.last,
          _state(
            DataExportPhase.failed,
            failure: DataExportFailure.unexpected,
            answers: 1,
          ),
        );
        verify(
          () => logger.error(
            any(),
            error: error,
            stackTrace: any(named: 'stackTrace'),
          ),
        ).called(1);
      });
    });

    test('a sink that throws fails as saveFailed', () {
      run((async, cubit, states) {
        assembles(() async => _bundle());
        saves(() async => throw Exception('disk full'));

        cubit.export();
        async.elapse(_dwell);

        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
          _state(DataExportPhase.saving, run: DataExportRun.export),
          _state(
            DataExportPhase.failed,
            failure: DataExportFailure.saveFailed,
            answers: 1,
          ),
        ]);
      });
    });

    test('a retry clears the failure as it starts', () {
      run((async, cubit, states) {
        assembles(() async => throw const ExportNotAuthenticatedException());
        cubit.export();
        async.elapse(_dwell);
        states.clear();

        cubit.export();
        async.flushMicrotasks();

        expect(states, [
          _state(
            DataExportPhase.assembling,
            run: DataExportRun.export,
            answers: 1,
          ),
        ]);
      });
    });
  });

  test('export while assembling is ignored', () {
    run((async, cubit, states) {
      final assembled = Completer<UserDataExportBundle>();
      assembles(() => assembled.future);

      cubit
        ..export()
        ..export()
        ..refreshAndExport()
        ..saveAnyway();
      async.flushMicrotasks();

      verify(
        () => assemble(any(), refresh: any(named: 'refresh')),
      ).called(1);
      expect(states, [
        _state(DataExportPhase.assembling, run: DataExportRun.export),
      ]);
    });
  });

  test('export while saving is ignored', () {
    run((async, cubit, states) {
      final saved = Completer<UserDataExportSaveResult>();
      assembles(() async => _bundle());
      saves(() => saved.future);

      cubit.export();
      async.flushMicrotasks();
      cubit
        ..export()
        ..refreshAndExport();
      async.flushMicrotasks();

      verify(
        () => assemble(any(), refresh: any(named: 'refresh')),
      ).called(1);
      expect(
        cubit.state,
        _state(DataExportPhase.saving, run: DataExportRun.export),
      );
    });
  });

  group('the session ending mid-assemble emits nothing more', () {
    test('when the bundle then arrives confirmed', () {
      run((async, cubit, states) {
        final assembled = Completer<UserDataExportBundle>();
        assembles(() => assembled.future);
        cubit.export();
        async.flushMicrotasks();

        unawaited(cubit.close());
        async.flushMicrotasks();
        assembled.complete(_bundle());
        async.elapse(_dwell);

        expect(cubit.isClosed, isTrue);
        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
        ]);
        verifyNever(
          () => sink.save(
            fileName: any(named: 'fileName'),
            bytes: any(named: 'bytes'),
          ),
        );
      });
    });

    test('when the assemble then fails', () {
      run((async, cubit, states) {
        final assembled = Completer<UserDataExportBundle>();
        assembles(() => assembled.future);
        cubit.export();
        async.flushMicrotasks();

        unawaited(cubit.close());
        async.flushMicrotasks();
        assembled.completeError(const ExportNotAuthenticatedException());
        async.elapse(_dwell);

        expect(cubit.isClosed, isTrue);
        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
        ]);
      });
    });
  });

  test('closing while saving emits nothing more', () {
    run((async, cubit, states) {
      final saved = Completer<UserDataExportSaveResult>();
      assembles(() async => _bundle());
      saves(() => saved.future);
      cubit.export();
      async.flushMicrotasks();
      expect(
        cubit.state,
        _state(DataExportPhase.saving, run: DataExportRun.export),
      );

      unawaited(cubit.close());
      async.flushMicrotasks();
      // A cancel is emitted without waiting for the dwell, so nothing but
      // the cubit's own check stands between it and a closed cubit.
      saved.complete(UserDataExportSaveResult.cancelled);
      async.elapse(_dwell);

      expect(cubit.isClosed, isTrue);
      expect(
        states.last,
        _state(DataExportPhase.saving, run: DataExportRun.export),
      );
    });
  });

  test('dismissOutcome retires a banner', () {
    run((async, cubit, states) {
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.saved);
      cubit.export();
      async.elapse(_dwell);
      expect(cubit.state, _state(DataExportPhase.saved, answers: 1));

      cubit.dismissOutcome();
      async.flushMicrotasks();

      expect(states.last, _state(DataExportPhase.ready, answers: 1));
    });
  });

  test('dismissOutcome leaves a failure, and the warning, in place', () {
    run((async, cubit, states) {
      toWarning(async, cubit, states);
      cubit.dismissOutcome();
      expect(cubit.state.phase, DataExportPhase.unconfirmed);

      assembles(() async => throw const ExportNotAuthenticatedException());
      cubit.export();
      async.elapse(_dwell);
      cubit.dismissOutcome();

      expect(cubit.state.phase, DataExportPhase.failed);
    });
  });

  group('the state', () {
    test('isSuccess is a save or a download', () {
      for (final phase in DataExportPhase.values) {
        expect(
          _state(phase).isSuccess,
          phase == DataExportPhase.saved || phase == DataExportPhase.downloaded,
          reason: '$phase',
        );
      }
    });

    test('the buttons are up on the warning and through a run begun under '
        'it; the banner while it has keys', () {
      expect(
        _state(DataExportPhase.unconfirmed, keys: ['a']).showsWarningButtons,
        isTrue,
      );
      expect(
        _state(
          DataExportPhase.saving,
          run: DataExportRun.export,
          underWarning: true,
        ).showsWarningButtons,
        isTrue,
      );
      expect(
        _state(
          DataExportPhase.saving,
          run: DataExportRun.export,
        ).showsWarningButtons,
        isFalse,
      );
      expect(_state(DataExportPhase.ready).showsWarningBanner, isFalse);
      expect(
        _state(DataExportPhase.assembling, keys: ['a']).showsWarningBanner,
        isTrue,
      );
    });
  });

  group('the dwell', () {
    test('an answer that comes at once still leaves the busy state up for '
        'the dwell', () {
      run((async, cubit, states) {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));

        cubit.export();
        async.elapse(_dwell - _ms);
        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
        ]);

        async.elapse(_ms);
        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
          _state(
            DataExportPhase.unconfirmed,
            keys: ['gameCollection'],
            answers: 1,
          ),
        ]);
      });
    });

    test('a failure that comes at once waits for the dwell too', () {
      run((async, cubit, states) {
        toWarning(async, cubit, states);
        // A session read that fails at once, with nothing to wait on.
        assembles(
          () async => throw ExportSessionUnavailableException(
            cause: Exception('offline'),
          ),
        );

        cubit.refreshAndExport();
        async.elapse(_dwell - _ms);
        expect(states, hasLength(1));
        expect(states.single.phase, DataExportPhase.assembling);

        async.elapse(_ms);
        expect(states.last.phase, DataExportPhase.failed);
      });
    });

    test('"save this copy" holds its saving state for the dwell', () {
      run((async, cubit, states) {
        toWarning(async, cubit, states);
        saves(() async => UserDataExportSaveResult.saved);

        cubit.saveAnyway();
        async.elapse(_dwell - _ms);
        expect(states, hasLength(1));
        expect(states.single.phase, DataExportPhase.saving);

        async.elapse(_ms);
        expect(states.last.phase, DataExportPhase.saved);
      });
    });

    test('a slow answer is not held further', () {
      run((async, cubit, states) {
        final assembled = Completer<UserDataExportBundle>();
        assembles(() => assembled.future);

        cubit.export();
        async.elapse(_dwell * 3);
        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
        ]);

        assembled.complete(_bundle(unconfirmed: ['gameCollection']));
        async.flushMicrotasks();

        expect(states.last.phase, DataExportPhase.unconfirmed);
      });
    });

    test('closing during the dwell emits nothing more', () {
      run((async, cubit, states) {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));
        cubit.export();
        async.flushMicrotasks();

        unawaited(cubit.close());
        async.elapse(_dwell * 2);

        expect(cubit.isClosed, isTrue);
        expect(states, [
          _state(DataExportPhase.assembling, run: DataExportRun.export),
        ]);
      });
    });
  });
}
