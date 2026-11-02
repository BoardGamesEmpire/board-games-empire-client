import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late DataGatewayAccess access;
  late Completer<DataGateway> pendingRead;

  final row = gateway('dg_1', name: 'BGG');

  const load = DataGatewayDetailLoadRequested();
  const interview = DataGatewayDetailInterviewRequested();
  const dismiss = DataGatewayDetailOutcomeDismissed();
  DataGatewayDetailEvent switchOff(String name) =>
      DataGatewayDetailCapabilitySwitched(name, on: false);
  DataGatewayDetailEvent switchOn(String name) =>
      DataGatewayDetailCapabilitySwitched(name, on: true);

  const fetchCall = 'fetchOne(dg_1)';
  const interviewCall = 'interview(dg_1)';
  String writeCall(List<String> disabled) =>
      'setDisabledCapabilities(dg_1, $disabled)';

  const timedOut = DataGatewayTimedOutException('no answer in time');
  const conflict = DataGatewayConflictException('disabled', statusCode: 409);
  const notFound = DataGatewayNotFoundException('gone', statusCode: 404);

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = DataGatewayAccess(remote: remote);
  });

  tearDown(() => access.dispose());

  DataGatewayDetailBloc build() =>
      DataGatewayDetailBloc(remote: remote, id: 'dg_1', access: access);

  /// Answers each read with the next of [answers], and goes on answering with
  /// the last. A row is the answer, a future is waited on, and anything else
  /// is thrown.
  void reads(List<Object> answers) {
    var read = 0;
    remote.onFetchOne = (_) {
      final answer = answers[read < answers.length ? read : answers.length - 1];
      read++;
      return switch (answer) {
        final DataGateway row => Future.value(row),
        final Future<DataGateway> pending => pending,
        _ => Future.error(answer),
      };
    };
  }

  /// Answers each write with [from], holding the list it was sent.
  void echoingWrites(DataGateway from) {
    remote.onSetDisabledCapabilities = (_, disabled) async =>
        changed(from.copyWith(disabledCapabilities: disabled));
  }

  DataGatewayInterviewResult interviewed(
    DataGateway row, {
    bool succeeded = true,
  }) => DataGatewayInterviewResult(dataGateway: row, succeeded: succeeded);

  Future<void> send(
    DataGatewayDetailBloc bloc,
    DataGatewayDetailEvent event,
  ) async {
    bloc.add(event);
    await pumpEventQueue();
  }

  group('reading', () {
    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'reads the row',
      setUp: () => reads([row]),
      build: build,
      act: (bloc) => bloc.add(load),
      expect: () => [
        const DataGatewayDetailLoading(),
        DataGatewayDetailReady(gateway: row),
      ],
      verify: (_) {
        expect(remote.calls, [fetchCall]);
        expect(access.value.read, DataGatewayRead.granted);
      },
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a refused read is denied',
      setUp: () => reads([forbidden()]),
      build: build,
      act: (bloc) => bloc.add(load),
      expect: () => [
        const DataGatewayDetailLoading(),
        const DataGatewayDetailDenied(),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.denied),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a missing row is gone',
      setUp: () => reads([notFound]),
      build: build,
      act: (bloc) => bloc.add(load),
      expect: () => [
        const DataGatewayDetailLoading(),
        const DataGatewayDetailGone(),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.unknown),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'another failed read is failed, and retry reads again',
      setUp: () => reads([unreachable(), row]),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, load);
      },
      expect: () => [
        const DataGatewayDetailLoading(),
        const DataGatewayDetailFailed(),
        const DataGatewayDetailLoading(),
        DataGatewayDetailReady(gateway: row),
      ],
    );

    final newer = row.copyWith(name: 'BGG, renamed');

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a read again keeps the row on screen while it runs',
      setUp: () {
        pendingRead = Completer<DataGateway>();
        reads([row, pendingRead.future]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, load);
        expect(bloc.state, DataGatewayDetailReady(gateway: row));
        pendingRead.complete(newer);
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayDetailLoading(),
        DataGatewayDetailReady(gateway: row),
        DataGatewayDetailReady(gateway: newer),
      ],
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'of two overlapping reads, the one asked for last wins, even when the '
      'other answers after it',
      setUp: () {
        pendingRead = Completer<DataGateway>();
        reads([pendingRead.future, newer]);
      },
      build: build,
      act: (bloc) async {
        bloc
          ..add(load)
          ..add(load);
        await pumpEventQueue();
        pendingRead.complete(row);
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayDetailLoading(),
        DataGatewayDetailReady(gateway: newer),
      ],
    );

    for (final (answered, error, down)
        in <(String, Object, DataGatewayDetailState)>[
          ('fails', unreachable(), const DataGatewayDetailFailed()),
          ('is refused', forbidden(), const DataGatewayDetailDenied()),
          ('finds it gone', notFound, const DataGatewayDetailGone()),
        ]) {
      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a read that $answered with no action running takes the row down, so '
        'nothing is sent, and the last outcome shows when a read brings it back',
        setUp: () {
          reads([row, error, row]);
          remote.onInterview = (_) async => interviewed(row, succeeded: false);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, interview);
          await send(bloc, load);
          await send(bloc, interview);
          await send(bloc, switchOff('B'));
          await send(bloc, load);
        },
        skip: 4,
        expect: () => [
          down,
          const DataGatewayDetailLoading(),
          DataGatewayDetailReady(
            gateway: row,
            outcome: DataGatewayDetailOutcome.interviewFailed,
          ),
        ],
        verify: (_) => expect(remote.calls, [
          fetchCall,
          interviewCall,
          fetchCall,
          fetchCall,
        ]),
      );
    }
  });

  final after = row.copyWith(
    interview: const DataGatewayInterviewStatus(interviewed: true),
  );
  final disabled = row.copyWith(enabled: false);
  final interviewing = DataGatewayDetailReady(
    gateway: row,
    busy: DataGatewayDetailBusy.interview,
  );
  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: success replaces the row',
    setUp: () {
      reads([row]);
      remote.onInterview = (_) async => interviewed(after);
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [
      interviewing,
      DataGatewayDetailReady(
        gateway: after,
        outcome: DataGatewayDetailOutcome.interviewDone,
      ),
    ],
    verify: (_) => expect(remote.calls, [fetchCall, interviewCall]),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: a failed attempt reports it and keeps the answer row',
    setUp: () {
      reads([row]);
      remote.onInterview = (_) async => interviewed(after, succeeded: false);
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [
      interviewing,
      DataGatewayDetailReady(
        gateway: after,
        outcome: DataGatewayDetailOutcome.interviewFailed,
      ),
    ],
    verify: (_) => expect(remote.calls, [fetchCall, interviewCall]),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: a timeout says unknown and reads again',
    setUp: () {
      reads([row, after]);
      remote.onInterview = (_) async => throw timedOut;
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [
      interviewing,
      DataGatewayDetailReady(
        gateway: row,
        outcome: DataGatewayDetailOutcome.interviewUnknown,
      ),
      DataGatewayDetailReady(
        gateway: after,
        outcome: DataGatewayDetailOutcome.interviewUnknown,
      ),
    ],
    verify: (_) => expect(remote.calls, [fetchCall, interviewCall, fetchCall]),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: a conflict says disabled and reads again',
    setUp: () {
      reads([row, disabled]);
      remote.onInterview = (_) async => throw conflict;
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [
      interviewing,
      DataGatewayDetailReady(
        gateway: row,
        outcome: DataGatewayDetailOutcome.interviewDisabled,
      ),
      DataGatewayDetailReady(
        gateway: disabled,
        outcome: DataGatewayDetailOutcome.interviewDisabled,
      ),
    ],
    verify: (_) => expect(remote.calls, [fetchCall, interviewCall, fetchCall]),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: a 404 is gone',
    setUp: () {
      reads([row]);
      remote.onInterview = (_) async => throw notFound;
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [interviewing, const DataGatewayDetailGone()],
    verify: (_) => expect(remote.calls, [fetchCall, interviewCall]),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: a 403 refuses and hides changes',
    setUp: () {
      reads([row]);
      remote.onInterview = (_) async => throw forbidden();
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [
      interviewing,
      DataGatewayDetailReady(
        gateway: row,
        mayChange: false,
        outcome: DataGatewayDetailOutcome.refused,
      ),
    ],
    verify: (_) {
      expect(access.value.mayChange, isFalse);
      expect(remote.calls, [fetchCall, interviewCall]);
    },
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: another failure reports no answer and reads the row, which '
    'may have changed',
    setUp: () {
      reads([row, after]);
      remote.onInterview = (_) async => throw unreachable();
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => [
      interviewing,
      DataGatewayDetailReady(
        gateway: row,
        outcome: DataGatewayDetailOutcome.interviewNoAnswer,
      ),
      DataGatewayDetailReady(
        gateway: after,
        outcome: DataGatewayDetailOutcome.interviewNoAnswer,
      ),
    ],
    verify: (_) => expect(remote.calls, [fetchCall, interviewCall, fetchCall]),
  );

  for (final (cause, failure) in <(String, DataGatewayRemoteException)>[
    (
      "a proxy's 504",
      const DataGatewayTransientException('bad gateway', statusCode: 504),
    ),
    (
      'a body that could not be read',
      const DataGatewayPermanentException('unreadable', statusCode: 200),
    ),
  ]) {
    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      're-interview: after $cause, it is not sent again until the row has been '
      'read, because the server may still be interviewing',
      setUp: () {
        pendingRead = Completer<DataGateway>();
        reads([row, pendingRead.future]);
        var attempts = 0;
        remote.onInterview = (_) async {
          if (++attempts == 1) throw failure;
          return interviewed(row);
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, interview);
        expect(remote.calls, [fetchCall, interviewCall, fetchCall]);
        pendingRead.complete(row);
        await pumpEventQueue();
        await send(bloc, interview);
      },
      verify: (_) => expect(remote.calls, [
        fetchCall,
        interviewCall,
        fetchCall,
        interviewCall,
      ]),
    );
  }

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview on a disabled row is not sent',
    setUp: () => reads([disabled]),
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
    },
    skip: 2,
    expect: () => <DataGatewayDetailState>[],
    verify: (_) => expect(remote.calls, [fetchCall]),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: keeps the last outcome until the next one answers',
    setUp: () {
      reads([row]);
      var attempts = 0;
      remote.onInterview = (_) async =>
          interviewed(after, succeeded: ++attempts > 1);
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
      await send(bloc, interview);
    },
    skip: 4,
    expect: () => [
      DataGatewayDetailReady(
        gateway: after,
        busy: DataGatewayDetailBusy.interview,
        outcome: DataGatewayDetailOutcome.interviewFailed,
      ),
      DataGatewayDetailReady(
        gateway: after,
        outcome: DataGatewayDetailOutcome.interviewDone,
      ),
    ],
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    'an action that finds the row gone takes the last outcome with it, so a '
    'read that brings the row back does not show it',
    setUp: () {
      reads([row, after]);
      var attempts = 0;
      remote.onInterview = (_) async {
        if (++attempts > 1) throw notFound;
        return interviewed(after, succeeded: false);
      };
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
      await send(bloc, interview);
      await send(bloc, load);
    },
    verify: (bloc) =>
        expect(bloc.state, DataGatewayDetailReady(gateway: after)),
  );

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    're-interview: after a timeout, it is not sent again until the row has '
    'been read, because the server may still be interviewing',
    setUp: () {
      pendingRead = Completer<DataGateway>();
      reads([row, pendingRead.future]);
      var attempts = 0;
      remote.onInterview = (_) async {
        if (++attempts == 1) throw timedOut;
        return interviewed(row);
      };
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
      await send(bloc, interview);
      expect(remote.calls, [fetchCall, interviewCall, fetchCall]);
      pendingRead.complete(row);
      await pumpEventQueue();
      await send(bloc, interview);
    },
    verify: (_) => expect(remote.calls, [
      fetchCall,
      interviewCall,
      fetchCall,
      interviewCall,
    ]),
  );

  group('capability switches', () {
    DataGateway off(List<String> names) =>
        row.copyWith(disabledCapabilities: names);

    DataGatewayDetailReady writing(List<String> names) =>
        DataGatewayDetailReady(
          gateway: off(names),
          busy: DataGatewayDetailBusy.capabilities,
        );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'switching off appends to the server list',
      setUp: () {
        reads([
          off(['A']),
        ]);
        echoingWrites(row);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('B'));
      },
      skip: 2,
      expect: () => [
        writing(['A']),
        // A write that works has nothing to report: the switch has moved.
        DataGatewayDetailReady(gateway: off(['A', 'B'])),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall,
        writeCall(['A', 'B']),
      ]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'switching on removes only that name',
      setUp: () {
        reads([
          off(['FutureThing', 'Search']),
        ]);
        echoingWrites(row);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOn('Search'));
      },
      skip: 3,
      expect: () => [
        DataGatewayDetailReady(gateway: off(['FutureThing'])),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall,
        writeCall(['FutureThing']),
      ]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a name it cannot label is kept on a write',
      setUp: () {
        reads([
          off(['FutureThing']),
        ]);
        echoingWrites(row);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('Search'));
      },
      verify: (_) => expect(remote.calls, [
        fetchCall,
        writeCall(['FutureThing', 'Search']),
      ]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'the second write builds on the first answer',
      // The server keeps the list in its own form, so what the first write
      // sent is not what the row holds after it.
      setUp: () {
        reads([row]);
        remote.onSetDisabledCapabilities = (_, disabled) async =>
            changed(disabled.contains('B') ? off(disabled) : off(['A']));
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('Z'));
        await send(bloc, switchOff('B'));
      },
      verify: (_) => expect(remote.calls, [
        fetchCall,
        writeCall(['Z']),
        writeCall(['A', 'B']),
      ]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a switch that would change nothing sends nothing',
      setUp: () => reads([
        off(['A']),
      ]),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('A'));
        await send(bloc, switchOn('B'));
      },
      skip: 2,
      expect: () => <DataGatewayDetailState>[],
      verify: (_) => expect(remote.calls, [fetchCall]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a capability failure keeps the row and reports it',
      setUp: () {
        reads([row]);
        remote.onSetDisabledCapabilities = (_, _) async => throw unreachable();
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('B'));
      },
      skip: 2,
      expect: () => [
        writing([]),
        DataGatewayDetailReady(
          gateway: row,
          outcome: DataGatewayDetailOutcome.capabilityFailed,
        ),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall,
        writeCall(['B']),
        fetchCall,
      ]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a write that works takes the last outcome down as it answers, and '
      'reports none',
      setUp: () {
        reads([row]);
        var attempts = 0;
        remote.onSetDisabledCapabilities = (_, disabled) async {
          if (++attempts == 1) throw unreachable();
          return changed(off(disabled));
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('B'));
        await send(bloc, switchOff('B'));
      },
      skip: 4,
      expect: () => [
        DataGatewayDetailReady(
          gateway: off(const []),
          busy: DataGatewayDetailBusy.capabilities,
          outcome: DataGatewayDetailOutcome.capabilityFailed,
        ),
        DataGatewayDetailReady(gateway: off(['B'])),
      ],
    );

    group('what is pressed during a write', () {
      late Completer<DataGatewayChangeResult> firstWrite;

      /// Holds the first write, and answers the rest at once.
      void holdingTheFirstWrite() {
        reads([row]);
        firstWrite = Completer();
        var writes = 0;
        remote.onSetDisabledCapabilities = (_, disabled) async =>
            ++writes == 1 ? firstWrite.future : changed(off(disabled));
      }

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'another switch goes when the write has answered, built from its row',
        setUp: holdingTheFirstWrite,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, switchOff('A'));
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
          ]);
          firstWrite.complete(changed(off(['B'])));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
            writeCall(['B', 'A']),
          ]);
          expect(
            (bloc.state as DataGatewayDetailReady).gateway.disabledCapabilities,
            ['B', 'A'],
          );
        },
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a double press writes once',
        setUp: holdingTheFirstWrite,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, switchOff('B'));
          firstWrite.complete(changed(off(['B'])));
          await pumpEventQueue();
        },
        verify: (_) => expect(remote.calls, [
          fetchCall,
          writeCall(['B']),
        ]),
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a switch pressed both ways goes as last pressed',
        setUp: holdingTheFirstWrite,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, switchOff('A'));
          await send(bloc, switchOn('A'));
          firstWrite.complete(changed(off(['B'])));
          await pumpEventQueue();
        },
        verify: (_) => expect(remote.calls, [
          fetchCall,
          writeCall(['B']),
        ]),
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'an interview says it is waiting, and goes after the switches',
        setUp: () {
          holdingTheFirstWrite();
          remote.onInterview = (_) async => interviewed(off(['B', 'A']));
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, interview);
          await send(bloc, switchOff('A'));
          expect(
            bloc.state,
            DataGatewayDetailReady(
              gateway: row,
              busy: DataGatewayDetailBusy.capabilities,
              interviewWaiting: true,
            ),
          );
          firstWrite.complete(changed(off(['B'])));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
            writeCall(['B', 'A']),
            interviewCall,
          ]);
          expect(
            bloc.state,
            DataGatewayDetailReady(
              gateway: off(['B', 'A']),
              outcome: DataGatewayDetailOutcome.interviewDone,
            ),
          );
        },
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'an interview waiting on a write whose row comes back disabled is not '
        'sent, and stops saying it is waiting',
        setUp: holdingTheFirstWrite,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, interview);
          firstWrite.complete(changed(off(['B']).copyWith(enabled: false)));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
          ]);
          expect(
            bloc.state,
            DataGatewayDetailReady(
              gateway: off(['B']).copyWith(enabled: false),
            ),
          );
        },
      );

      for (final (cause, failure, reads_) in <(String, Object, int)>[
        ('a lost answer', unreachable(), 2),
        ('a refusal', forbidden(), 1),
      ]) {
        blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
          'a write ending in $cause drops what was waiting',
          setUp: holdingTheFirstWrite,
          build: build,
          act: (bloc) async {
            await send(bloc, load);
            await send(bloc, switchOff('B'));
            await send(bloc, switchOff('A'));
            await send(bloc, interview);
            firstWrite.completeError(failure);
            await pumpEventQueue();
          },
          verify: (bloc) {
            expect(remote.calls, [
              fetchCall,
              writeCall(['B']),
              if (reads_ == 2) fetchCall,
            ]);
            expect(
              (bloc.state as DataGatewayDetailReady).interviewWaiting,
              isFalse,
            );
          },
        );
      }

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a write that finds the row gone drops what was waiting, so a read '
        'that brings it back sends none of it',
        setUp: holdingTheFirstWrite,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, switchOff('A'));
          await send(bloc, interview);
          firstWrite.completeError(notFound);
          await pumpEventQueue();
          expect(bloc.state, const DataGatewayDetailGone());

          await send(bloc, load);
          expect(bloc.state, DataGatewayDetailReady(gateway: row));
          await send(bloc, switchOff('C'));
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
            fetchCall,
            writeCall(['C']),
          ]);
          expect(bloc.state, DataGatewayDetailReady(gateway: off(['C'])));
        },
      );
    });

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a 404 on a write is gone',
      setUp: () {
        reads([row]);
        remote.onSetDisabledCapabilities = (_, _) async => throw notFound;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('B'));
      },
      skip: 2,
      expect: () => [writing([]), const DataGatewayDetailGone()],
      verify: (_) => expect(remote.calls, [
        fetchCall,
        writeCall(['B']),
      ]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a 403 on a write refuses and hides changes',
      setUp: () {
        reads([row]);
        remote.onSetDisabledCapabilities = (_, _) async => throw forbidden();
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, switchOff('B'));
      },
      skip: 2,
      expect: () => [
        writing([]),
        DataGatewayDetailReady(
          gateway: row,
          mayChange: false,
          outcome: DataGatewayDetailOutcome.refused,
        ),
      ],
      verify: (_) {
        expect(access.value.mayChange, isFalse);
        expect(remote.calls, [
          fetchCall,
          writeCall(['B']),
        ]);
      },
    );

    group('a write whose answer was lost, which may have applied', () {
      void losingTheFirstWrite() {
        var attempts = 0;
        remote.onSetDisabledCapabilities = (_, disabled) async {
          if (++attempts == 1) throw unreachable();
          return changed(off(disabled));
        };
      }

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'the next switch builds on the row read again',
        setUp: () {
          reads([
            row,
            off(['B']),
          ]);
          losingTheFirstWrite();
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, switchOff('C'));
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
            fetchCall,
            writeCall(['B', 'C']),
          ]);
          expect(bloc.state, DataGatewayDetailReady(gateway: off(['B', 'C'])));
        },
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a switch while that read is out is dropped: it would build on the '
        'old list, and switch the first change back on',
        setUp: () {
          pendingRead = Completer<DataGateway>();
          reads([row, pendingRead.future]);
          losingTheFirstWrite();
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          await send(bloc, switchOff('C'));
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
            fetchCall,
          ]);
          pendingRead.complete(off(['B']));
          await pumpEventQueue();
          await send(bloc, switchOff('C'));
        },
        verify: (_) => expect(remote.calls, [
          fetchCall,
          writeCall(['B']),
          fetchCall,
          writeCall(['B', 'C']),
        ]),
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'that read failing takes the row down, so nothing can be built on '
        'the old list, and its outcome shows when a read brings the row back',
        setUp: () {
          reads([
            row,
            unreachable(),
            off(['B']),
          ]);
          losingTheFirstWrite();
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, switchOff('B'));
          expect(bloc.state, const DataGatewayDetailFailed());
          await send(bloc, switchOff('C'));
          await send(bloc, load);
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall,
            writeCall(['B']),
            fetchCall,
            fetchCall,
          ]);
          expect(
            bloc.state,
            DataGatewayDetailReady(
              gateway: off(['B']),
              outcome: DataGatewayDetailOutcome.capabilityFailed,
            ),
          );
        },
      );
    });
  });

  group('overlap', () {
    final answer = row.copyWith(name: 'What the action answered');
    final old = row.copyWith(name: 'Older than the action');
    final reread = row.copyWith(name: 'Read after the action');

    /// Scripts [action] to wait, and answers with the function that ends it
    /// with [answer].
    void Function() holding(DataGatewayDetailBusy action) {
      switch (action) {
        case DataGatewayDetailBusy.interview:
          final pending = Completer<DataGatewayInterviewResult>();
          remote.onInterview = (_) => pending.future;
          return () => pending.complete(interviewed(answer));
        case DataGatewayDetailBusy.capabilities:
          final pending = Completer<DataGatewayChangeResult>();
          remote.onSetDisabledCapabilities = (_, _) => pending.future;
          return () => pending.complete(changed(answer));
      }
    }

    DataGatewayDetailEvent asking(
      DataGatewayDetailBusy action, {
      String capability = 'Search',
    }) => switch (action) {
      DataGatewayDetailBusy.interview => interview,
      DataGatewayDetailBusy.capabilities => switchOff(capability),
    };

    String callOf(DataGatewayDetailBusy action) => switch (action) {
      DataGatewayDetailBusy.interview => interviewCall,
      DataGatewayDetailBusy.capabilities => writeCall(['Search']),
    };

    DataGatewayDetailOutcome? outcomeOf(DataGatewayDetailBusy action) =>
        switch (action) {
          DataGatewayDetailBusy.interview =>
            DataGatewayDetailOutcome.interviewDone,
          DataGatewayDetailBusy.capabilities => null,
        };

    const first = DataGatewayDetailBusy.interview;
    for (final second in DataGatewayDetailBusy.values) {
      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'an action asked for during an interview is dropped: ${second.name}',
        setUp: () {
          reads([row]);
          holding(first);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          // A double press, and a press once the first is under way.
          bloc
            ..add(asking(first))
            ..add(asking(second, capability: 'Fetch'));
          await pumpEventQueue();
          await send(bloc, asking(second, capability: 'Fetch'));
        },
        skip: 2,
        expect: () => [DataGatewayDetailReady(gateway: row, busy: first)],
        verify: (_) => expect(remote.calls, [fetchCall, callOf(first)]),
      );
    }

    for (final action in DataGatewayDetailBusy.values) {
      late void Function() endAction;

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a read answering during an action is dropped, and read again after '
        '(${action.name})',
        setUp: () {
          reads([row, old, reread]);
          endAction = holding(action);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, asking(action));
          await send(bloc, load);
          expect(
            bloc.state,
            DataGatewayDetailReady(gateway: row, busy: action),
          );
          endAction();
          await pumpEventQueue();
        },
        skip: 2,
        expect: () => [
          DataGatewayDetailReady(gateway: row, busy: action),
          DataGatewayDetailReady(gateway: answer, outcome: outcomeOf(action)),
          DataGatewayDetailReady(gateway: reread, outcome: outcomeOf(action)),
        ],
        verify: (_) => expect(remote.calls, [
          fetchCall,
          callOf(action),
          fetchCall,
          fetchCall,
        ]),
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a read still in flight when an action ends is dropped, and read '
        'again (${action.name})',
        setUp: () {
          pendingRead = Completer<DataGateway>();
          reads([row, pendingRead.future, reread]);
          endAction = holding(action);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, asking(action));
          await send(bloc, load);
          endAction();
          await pumpEventQueue();
          pendingRead.complete(old);
          await pumpEventQueue();
        },
        skip: 2,
        expect: () => [
          DataGatewayDetailReady(gateway: row, busy: action),
          DataGatewayDetailReady(gateway: answer, outcome: outcomeOf(action)),
          DataGatewayDetailReady(gateway: reread, outcome: outcomeOf(action)),
        ],
        verify: (_) => expect(remote.calls, [
          fetchCall,
          callOf(action),
          fetchCall,
          fetchCall,
        ]),
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a read in flight when an action ends cannot land before the next '
        'read starts (${action.name})',
        // Answered in the same turn, the old read lands after the action has
        // cleared busy and before the read it asked for has started, so
        // nothing but the sequence stops it.
        setUp: () {
          pendingRead = Completer<DataGateway>();
          reads([row, pendingRead.future, reread]);
          endAction = holding(action);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, asking(action));
          await send(bloc, load);
          endAction();
          pendingRead.complete(old);
          await pumpEventQueue();
        },
        skip: 2,
        expect: () => [
          DataGatewayDetailReady(gateway: row, busy: action),
          DataGatewayDetailReady(gateway: answer, outcome: outcomeOf(action)),
          DataGatewayDetailReady(gateway: reread, outcome: outcomeOf(action)),
        ],
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a read sent before an action and still in flight when it ends is '
        'dropped too (${action.name})',
        setUp: () {
          pendingRead = Completer<DataGateway>();
          reads([row, pendingRead.future, reread]);
          endAction = holding(action);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, load);
          await send(bloc, asking(action));
          endAction();
          await pumpEventQueue();
          pendingRead.complete(old);
          await pumpEventQueue();
        },
        skip: 2,
        expect: () => [
          DataGatewayDetailReady(gateway: row, busy: action),
          DataGatewayDetailReady(gateway: answer, outcome: outcomeOf(action)),
          DataGatewayDetailReady(gateway: reread, outcome: outcomeOf(action)),
        ],
      );
    }

    for (final (answered, error) in <(String, Object)>[
      ('fails', unreachable()),
      ('is refused', forbidden()),
      ('finds it gone', notFound),
    ]) {
      late void Function() endAction;

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'a read that $answered during an action does not take the row down, '
        'and is read again after',
        setUp: () {
          reads([row, error, reread]);
          endAction = holding(DataGatewayDetailBusy.interview);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, interview);
          await send(bloc, load);
          expect(access.value.read, DataGatewayRead.granted);
          endAction();
          await pumpEventQueue();
        },
        skip: 2,
        expect: () => [
          DataGatewayDetailReady(
            gateway: row,
            busy: DataGatewayDetailBusy.interview,
          ),
          DataGatewayDetailReady(
            gateway: answer,
            outcome: DataGatewayDetailOutcome.interviewDone,
          ),
          DataGatewayDetailReady(
            gateway: reread,
            outcome: DataGatewayDetailOutcome.interviewDone,
          ),
        ],
      );
    }

    late void Function() endInterview;

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a read dropped during one action is read again once, and not again '
      'after the next',
      setUp: () {
        reads([row, old, reread]);
        endInterview = holding(DataGatewayDetailBusy.interview);
        echoingWrites(reread);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, load);
        endInterview();
        await pumpEventQueue();
        await send(bloc, switchOff('Search'));
      },
      verify: (_) => expect(remote.calls, [
        fetchCall,
        interviewCall,
        fetchCall,
        fetchCall,
        writeCall(['Search']),
      ]),
    );

    late Completer<DataGateway> lateRead;
    late Completer<DataGatewayInterviewResult> pendingInterview;

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'an action that finds the row gone reads nothing more, and a read in '
      'flight cannot bring the row back',
      setUp: () {
        lateRead = Completer<DataGateway>();
        pendingInterview = Completer<DataGatewayInterviewResult>();
        reads([row, lateRead.future]);
        remote.onInterview = (_) => pendingInterview.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, load);
        pendingInterview.completeError(notFound);
        await pumpEventQueue();
        lateRead.complete(old);
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        DataGatewayDetailReady(
          gateway: row,
          busy: DataGatewayDetailBusy.interview,
        ),
        const DataGatewayDetailGone(),
      ],
      verify: (_) =>
          expect(remote.calls, [fetchCall, interviewCall, fetchCall]),
    );
  });

  group('closing during a re-interview does not throw', () {
    late Completer<DataGatewayInterviewResult> pending;

    // Run as each blocTest's own setUp, inside its zone. A future's error
    // does not cross into another error zone, so one made in a group setUp
    // never reaches the handler.
    void holdingTheInterview() {
      pending = Completer<DataGatewayInterviewResult>();
      reads([row]);
      remote.onInterview = (_) => pending.future;
    }

    for (final (ends, end) in <(String, void Function())>[
      ('it succeeds', () => pending.complete(interviewed(row))),
      ('it times out', () => pending.completeError(timedOut)),
      ('the row is disabled', () => pending.completeError(conflict)),
    ]) {
      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'when $ends after the close',
        setUp: holdingTheInterview,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, interview);
          await bloc.close();
          end();
          await pumpEventQueue();
        },
        verify: (_) => expect(remote.calls, [fetchCall, interviewCall]),
      );

      blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
        'when $ends in the same turn as the close',
        setUp: holdingTheInterview,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, interview);
          final closing = bloc.close();
          end();
          await closing;
          await pumpEventQueue();
        },
        verify: (_) => expect(remote.calls, [fetchCall, interviewCall]),
      );
    }

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'when a read landed during it, which wants one more read after',
      setUp: holdingTheInterview,
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, load);
        final closing = bloc.close();
        pending.complete(interviewed(row));
        await closing;
        await pumpEventQueue();
      },
      verify: (_) =>
          expect(remote.calls, [fetchCall, interviewCall, fetchCall]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'and a refusal that lands after the close still tells the session',
      setUp: holdingTheInterview,
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await bloc.close();
        pending.completeError(forbidden());
        await pumpEventQueue();
      },
      verify: (_) => expect(access.value.mayChange, isFalse),
    );
  });

  test('closing stops listening to the session', () async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    final bloc = build();
    await bloc.close();
    access.changeDenied();

    expect(errors, isEmpty);
  });

  group('a reader who may not change DataGateways', () {
    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'opens with changes hidden once the session has learned it, and sends '
      'nothing',
      setUp: () {
        reads([row]);
        access.changeDenied();
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, switchOff('B'));
      },
      skip: 1,
      expect: () => [DataGatewayDetailReady(gateway: row, mayChange: false)],
      verify: (_) => expect(remote.calls, [fetchCall]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'hides changes when another screen learns it',
      setUp: () => reads([row]),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        access.changeDenied();
      },
      skip: 2,
      expect: () => [DataGatewayDetailReady(gateway: row, mayChange: false)],
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'a refused change stops the next one being sent',
      setUp: () {
        reads([row]);
        remote.onInterview = (_) async => throw forbidden();
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, interview);
        await send(bloc, switchOff('B'));
      },
      verify: (_) => expect(remote.calls, [fetchCall, interviewCall]),
    );

    blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
      'with no session to tell, a refusal still hides changes on this screen',
      setUp: () {
        reads([row]);
        remote.onInterview = (_) async => throw forbidden();
      },
      build: () => DataGatewayDetailBloc(remote: remote, id: 'dg_1'),
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, interview);
        await send(bloc, switchOff('B'));
      },
      verify: (bloc) {
        expect(
          bloc.state,
          DataGatewayDetailReady(
            gateway: row,
            mayChange: false,
            outcome: DataGatewayDetailOutcome.refused,
          ),
        );
        expect(remote.calls, [fetchCall, interviewCall]);
      },
    );
  });

  blocTest<DataGatewayDetailBloc, DataGatewayDetailState>(
    'dismissing the outcome clears it',
    setUp: () {
      reads([row]);
      remote.onInterview = (_) async => interviewed(row);
    },
    build: build,
    act: (bloc) async {
      await send(bloc, load);
      await send(bloc, interview);
      await send(bloc, dismiss);
    },
    skip: 4,
    expect: () => [DataGatewayDetailReady(gateway: row)],
  );

  group('helpers', () {
    test('dataGatewayCapabilityRows: known order, then unknown names, with a '
        'disabled undeclared one', () {
      final g = row.copyWith(
        capabilities: const ['ListLanguages', 'FutureThing', 'Search'],
        disabledCapabilities: const ['OtherThing', 'Fetch', 'Search'],
      );

      expect(dataGatewayCapabilityRows(g), [
        'Search',
        'Fetch',
        'ListLanguages',
        'FutureThing',
        'OtherThing',
      ]);
    });

    test('dataGatewayCapabilityRows: nothing declared is no rows', () {
      expect(dataGatewayCapabilityRows(row), isEmpty);
    });

    const languages = DataGatewaySection(
      capability: DataGatewayCapabilities.listLanguages,
    );
    const platforms = DataGatewaySection(
      capability: DataGatewayCapabilities.listPlatforms,
    );
    const mechanics = DataGatewaySection(
      capability: DataGatewayCapabilities.listMechanics,
    );

    test('dataGatewayListRows: keeps a switched-off list in its place, and '
        'leaves out an undeclared one', () {
      final g = row.copyWith(
        capabilities: const [
          DataGatewayCapabilities.search,
          DataGatewayCapabilities.listMechanics,
          DataGatewayCapabilities.listPlatforms,
          DataGatewayCapabilities.listLanguages,
        ],
        disabledCapabilities: const [
          DataGatewayCapabilities.listPlatforms,
          DataGatewayCapabilities.listCategories,
        ],
        sections: const [mechanics, platforms, languages],
      );

      expect(dataGatewayListRows(g), [
        (
          capability: DataGatewayCapabilities.listLanguages,
          section: languages,
          switchedOff: false,
        ),
        (
          capability: DataGatewayCapabilities.listPlatforms,
          section: platforms,
          switchedOff: true,
        ),
        (
          capability: DataGatewayCapabilities.listMechanics,
          section: mechanics,
          switchedOff: false,
        ),
      ]);
    });

    test(
      'dataGatewayListRows: a section this client has no name for shows after '
      'the ones it knows, while declared',
      () {
        const designers = DataGatewaySection(capability: 'ListDesigners');
        const publishers = DataGatewaySection(capability: 'ListPublishers');
        const artists = DataGatewaySection(capability: 'ListArtists');
        final g = row.copyWith(
          capabilities: const [
            'ListDesigners',
            'ListPublishers',
            DataGatewayCapabilities.listLanguages,
          ],
          disabledCapabilities: const ['ListPublishers'],
          sections: const [designers, publishers, artists, languages],
        );

        expect(dataGatewayListRows(g), [
          (
            capability: DataGatewayCapabilities.listLanguages,
            section: languages,
            switchedOff: false,
          ),
          (capability: 'ListDesigners', section: designers, switchedOff: false),
          (
            capability: 'ListPublishers',
            section: publishers,
            switchedOff: true,
          ),
        ]);
      },
    );

    test('dataGatewayListRows: a declared list with no section has null', () {
      final g = row.copyWith(
        capabilities: const [
          DataGatewayCapabilities.listLanguages,
          DataGatewayCapabilities.listMechanics,
        ],
        sections: const [mechanics],
      );

      expect(dataGatewayListRows(g), [
        (
          capability: DataGatewayCapabilities.listLanguages,
          section: null,
          switchedOff: false,
        ),
        (
          capability: DataGatewayCapabilities.listMechanics,
          section: mechanics,
          switchedOff: false,
        ),
      ]);
    });
  });
}
