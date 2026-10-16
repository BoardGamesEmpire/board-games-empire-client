import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late DataGatewayAccess access;

  final bgg = gateway(
    'dg_1',
    name: 'BGG',
    description: 'The BGG bridge',
    connectionUrl: 'bgg.internal',
    connectionPort: 50051,
  );

  const input = DataGatewayInput(
    name: 'BGG',
    connectionUrl: 'bgg.internal',
    connectionPort: 50051,
    description: 'The BGG bridge',
  );

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = DataGatewayAccess(remote: remote);
  });

  tearDown(() => access.dispose());

  DataGatewayFormBloc creating() =>
      DataGatewayFormBloc(remote: remote, access: access);

  DataGatewayFormBloc editing(String id) =>
      DataGatewayFormBloc(remote: remote, access: access, editingId: id);

  group('adding', () {
    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'opens an empty form',
      build: creating,
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [const DataGatewayFormEditing()],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'creates the DataGateway and reports the connect the server tried',
      setUp: () => remote.onCreate = (_) async => changed(
        bgg,
        attempted: DataGatewayConnectionAction.connect,
        succeeded: false,
      ),
      build: creating,
      act: (bloc) => bloc
        ..add(const DataGatewayFormStarted())
        ..add(const DataGatewayFormSubmitted(input)),
      skip: 1,
      expect: () => [
        const DataGatewayFormEditing(submitting: true),
        DataGatewayFormSaved(
          result: changed(
            bgg,
            attempted: DataGatewayConnectionAction.connect,
            succeeded: false,
          ),
          created: true,
        ),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a name already in use is said so, on the form',
      setUp: () => remote.onCreate = (_) async =>
          throw const DataGatewayNameInUseException('taken', statusCode: 409),
      build: creating,
      act: (bloc) => bloc
        ..add(const DataGatewayFormStarted())
        ..add(const DataGatewayFormSubmitted(input)),
      skip: 2,
      expect: () => [
        const DataGatewayFormEditing(failure: DataGatewayFormFailure.nameInUse),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'any other failure keeps the form and says the save failed',
      setUp: () => remote.onCreate = (_) async => throw unreachable(),
      build: creating,
      act: (bloc) => bloc
        ..add(const DataGatewayFormStarted())
        ..add(const DataGatewayFormSubmitted(input)),
      skip: 2,
      expect: () => [
        const DataGatewayFormEditing(failure: DataGatewayFormFailure.failed),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'ignores a second submit while one is in flight',
      setUp: () {
        final pending = Completer<DataGatewayChangeResult>();
        remote.onCreate = (_) => pending.future;
      },
      build: creating,
      act: (bloc) async {
        bloc
          ..add(const DataGatewayFormStarted())
          ..add(const DataGatewayFormSubmitted(input))
          ..add(const DataGatewayFormSubmitted(input));
        await pumpEventQueue();
      },
      verify: (_) => expect(remote.calls, ['create(BGG)']),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'editing the form retires a failure it showed',
      setUp: () => remote.onCreate = (_) async => throw unreachable(),
      build: creating,
      act: (bloc) async {
        bloc
          ..add(const DataGatewayFormStarted())
          ..add(const DataGatewayFormSubmitted(input));
        await pumpEventQueue();
        bloc.add(const DataGatewayFormFailureCleared());
      },
      skip: 3,
      expect: () => [const DataGatewayFormEditing()],
    );
  });

  group('editing', () {
    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'reads the row afresh and opens the form on it',
      setUp: () => remote.onFetchOne = (_) async => bgg,
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormLoading(),
        DataGatewayFormEditing(original: bgg),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'sends only the fields that changed (#41)',
      setUp: () {
        remote.onFetchOne = (_) async => bgg;
        remote.onUpdate = (_, changes) async {
          // A mismatch throws into the bloc, which reports a failed save
          // rather than the saved state below.
          expect(changes, const DataGatewayChanges(connectionPort: 50060));
          return changed(bgg.copyWith(connectionPort: 50060));
        };
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        bloc.add(
          DataGatewayFormSubmitted(input.copyWith(connectionPort: 50060)),
        );
      },
      skip: 3,
      expect: () => [
        DataGatewayFormSaved(
          result: changed(bgg.copyWith(connectionPort: 50060)),
          created: false,
        ),
      ],
      verify: (_) => expect(remote.calls, ['fetchOne(dg_1)', 'update(dg_1)']),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'emptying the description is a change that clears it',
      setUp: () {
        remote.onFetchOne = (_) async => bgg;
        remote.onUpdate = (_, changes) async {
          // A mismatch throws into the bloc, which reports a failed save
          // rather than the saved state below.
          expect(changes, const DataGatewayChanges(description: ''));
          return changed(bgg.copyWith(description: null));
        };
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        bloc.add(DataGatewayFormSubmitted(input.copyWith(description: null)));
      },
      skip: 3,
      expect: () => [
        DataGatewayFormSaved(
          result: changed(bgg.copyWith(description: null)),
          created: false,
        ),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      "can't be saved with nothing changed, and sends nothing (#41)",
      setUp: () => remote.onFetchOne = (_) async => bgg,
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        bloc.add(const DataGatewayFormSubmitted(input));
      },
      skip: 2,
      expect: () => [
        DataGatewayFormEditing(
          original: bgg,
          failure: DataGatewayFormFailure.nothingChanged,
        ),
      ],
      verify: (_) => expect(remote.calls, ['fetchOne(dg_1)']),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a row deleted meanwhile is said so',
      setUp: () {
        remote.onFetchOne = (_) async => bgg;
        remote.onUpdate = (_, _) async =>
            throw const DataGatewayNotFoundException('gone', statusCode: 404);
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        bloc.add(DataGatewayFormSubmitted(input.copyWith(name: 'BGG 2')));
      },
      skip: 3,
      expect: () => [
        DataGatewayFormEditing(
          original: bgg,
          failure: DataGatewayFormFailure.gone,
        ),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a row that does not exist opens as missing',
      setUp: () =>
          remote.onFetchOne = (_) async =>
              throw const DataGatewayNotFoundException('gone', statusCode: 404),
      build: () => editing('dg_404'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormLoading(),
        const DataGatewayFormMissing(),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a failed read offers a retry',
      setUp: () => remote.onFetchOne = (_) async => throw unreachable(),
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormLoading(),
        const DataGatewayFormLoadFailed(),
      ],
    );
  });

  group('access (#41)', () {
    late Completer<DataGatewayChangeResult> pending;

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refused read opens as access-denied, and the session learns it',
      setUp: () => remote.onFetchOne = (_) async => throw forbidden(),
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormLoading(),
        const DataGatewayFormDenied(),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.denied),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a user the session knows may not read opens as access-denied',
      setUp: () => access.readDenied(),
      build: creating,
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [const DataGatewayFormDenied()],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an edit asks the server even after a refused read, so a role raised '
      'since then gets the form',
      setUp: () {
        access.readDenied();
        remote.onFetchOne = (_) async => bgg;
      },
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormLoading(),
        DataGatewayFormEditing(original: bgg),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.granted),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refused save says the role may not change DataGateways, stops '
      'offering the save, and tells the session',
      setUp: () => remote.onCreate = (_) async => throw forbidden(),
      build: creating,
      act: (bloc) => bloc
        ..add(const DataGatewayFormStarted())
        ..add(const DataGatewayFormSubmitted(input)),
      skip: 2,
      expect: () => [const DataGatewayFormEditing(mayChange: false)],
      verify: (_) => expect(access.value.mayChange, isFalse),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'opens without the save once the session has learned it',
      setUp: () => access.changeDenied(),
      build: creating,
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [const DataGatewayFormEditing(mayChange: false)],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'stops offering the save when a change is refused elsewhere while it '
      'is open',
      // An action the list started before the form opened can be refused
      // after it has.
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.changeDenied();
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormEditing(),
        const DataGatewayFormEditing(mayChange: false),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add opened before the session heard shows access-denied when a '
      'read is refused elsewhere',
      // A deep link or a web reload on the add form can open it before the
      // sign-in check or the list beneath has answered.
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.readDenied();
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormEditing(),
        const DataGatewayFormDenied(),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add opened as access-denied opens the form when a read is granted '
      'later, so a role raised since then gets it',
      setUp: () => access.readDenied(),
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.readGranted();
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormDenied(),
        const DataGatewayFormEditing(),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a read refused elsewhere during an add leaves the save running, and a '
      'save that then fails shows access-denied, not the save again',
      setUp: () {
        pending = Completer<DataGatewayChangeResult>();
        remote.onCreate = (_) => pending.future;
      },
      build: creating,
      act: (bloc) async {
        bloc
          ..add(const DataGatewayFormStarted())
          ..add(const DataGatewayFormSubmitted(input));
        await pumpEventQueue();
        access.readDenied();
        await pumpEventQueue();
        pending.completeError(unreachable());
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormEditing(),
        const DataGatewayFormEditing(submitting: true),
        const DataGatewayFormDenied(),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refusal elsewhere during a save leaves the save running, and a save '
      'that then fails does not offer the save again',
      setUp: () {
        pending = Completer<DataGatewayChangeResult>();
        remote.onCreate = (_) => pending.future;
      },
      build: creating,
      act: (bloc) async {
        bloc
          ..add(const DataGatewayFormStarted())
          ..add(const DataGatewayFormSubmitted(input));
        await pumpEventQueue();
        access.changeDenied();
        await pumpEventQueue();
        pending.completeError(unreachable());
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormEditing(),
        const DataGatewayFormEditing(submitting: true),
        const DataGatewayFormEditing(submitting: true, mayChange: false),
        const DataGatewayFormEditing(
          mayChange: false,
          failure: DataGatewayFormFailure.failed,
        ),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'sends nothing once it has stopped offering the save',
      setUp: () => access.changeDenied(),
      build: creating,
      act: (bloc) => bloc
        ..add(const DataGatewayFormStarted())
        ..add(const DataGatewayFormSubmitted(input)),
      verify: (_) => expect(remote.calls, isEmpty),
    );
  });
}
