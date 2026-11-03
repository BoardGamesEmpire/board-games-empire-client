import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late FakeCallerAccessRepository access;

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

  /// A caller who may do anything to a DataGateway.
  final everything = FakeCallerAccessRepository.dataGateway(
    create: AccessExtent.all,
    read: AccessExtent.all,
    update: AccessExtent.all,
    delete: AccessExtent.all,
  );

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = FakeCallerAccessRepository(everything);
  });

  DataGatewayFormBloc creating() =>
      DataGatewayFormBloc(remote: remote, access: access);

  DataGatewayFormBloc editing(String id) =>
      DataGatewayFormBloc(remote: remote, access: access, editingId: id);

  group('adding', () {
    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'opens an empty form',
      build: creating,
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
      ],
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
        const DataGatewayFormEditing(
          submitting: true,
          maySave: true,
          accessKnown: true,
        ),
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
        const DataGatewayFormEditing(
          maySave: true,
          accessKnown: true,
          failure: DataGatewayFormFailure.nameInUse,
        ),
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
        const DataGatewayFormEditing(
          maySave: true,
          accessKnown: true,
          failure: DataGatewayFormFailure.failed,
        ),
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
      expect: () => [
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
      ],
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
        DataGatewayFormEditing(original: bgg, maySave: true, accessKnown: true),
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
          maySave: true,
          accessKnown: true,
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
          maySave: true,
          accessKnown: true,
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

  group('what the caller may do (#456)', () {
    late Completer<DataGatewayChangeResult> pending;

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      "an edit's read that succeeds while access is unknown asks access "
      'again',
      // The first ask failed with the server up, and nothing else would ask
      // again until a rehydrate trigger.
      setUp: () {
        remote.onFetchOne = (_) async => bgg;
        access.current = const CallerAccess.unknown();
      },
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      skip: 1,
      expect: () => [DataGatewayFormEditing(original: bgg)],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      "an edit's read that succeeds while access is known asks nothing",
      setUp: () => remote.onFetchOne = (_) async => bgg,
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      skip: 1,
      expect: () => [
        DataGatewayFormEditing(original: bgg, maySave: true, accessKnown: true),
      ],
      verify: (_) => expect(access.refreshCount, 0),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add with create offers the save',
      setUp: () => access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.some,
      ),
      build: creating,
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add while access is unknown shows read-only fields, then opens '
      'when create arrives',
      setUp: () => access.current = const CallerAccess.unknown(),
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
        );
      },
      expect: () => [
        isA<DataGatewayFormEditing>()
            .having((s) => s.maySave, 'maySave', isFalse)
            .having((s) => s.accessKnown, 'accessKnown', isFalse),
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add without a session to ask shows read-only fields, and reads as '
      'unknown',
      build: () => DataGatewayFormBloc(remote: remote),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [const DataGatewayFormEditing()],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an edit while access is unknown opens read-only and reads as unknown, '
      'then says why once access answers without update',
      setUp: () {
        access.current = const CallerAccess.unknown();
        remote.onFetchOne = (_) async => bgg;
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
          read: AccessExtent.all,
        );
      },
      expect: () => [
        const DataGatewayFormLoading(),
        isA<DataGatewayFormEditing>()
            .having((s) => s.original, 'original', bgg)
            .having((s) => s.maySave, 'maySave', isFalse)
            .having((s) => s.accessKnown, 'accessKnown', isFalse),
        DataGatewayFormEditing(original: bgg, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add without create is denied, and opens if create arrives',
      setUp: () => access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
      ),
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = everything;
      },
      expect: () => [
        const DataGatewayFormDenied(),
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an open add closes as access-denied when create falls',
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
      },
      expect: () => [
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
        const DataGatewayFormDenied(),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an edit offers the save on update, not on create',
      setUp: () {
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
          read: AccessExtent.all,
        );
        remote.onFetchOne = (_) async => bgg;
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
          update: AccessExtent.some,
        );
      },
      expect: () => [
        const DataGatewayFormLoading(),
        DataGatewayFormEditing(original: bgg, accessKnown: true),
        DataGatewayFormEditing(original: bgg, maySave: true, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an open edit stops offering the save when update falls',
      setUp: () => remote.onFetchOne = (_) async => bgg,
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
          read: AccessExtent.all,
          delete: AccessExtent.all,
        );
      },
      expect: () => [
        const DataGatewayFormLoading(),
        DataGatewayFormEditing(original: bgg, maySave: true, accessKnown: true),
        DataGatewayFormEditing(original: bgg, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refused read opens as access-denied, and asks access again',
      setUp: () => remote.onFetchOne = (_) async => throw forbidden(),
      build: () => editing('dg_1'),
      act: (bloc) => bloc.add(const DataGatewayFormStarted()),
      expect: () => [
        const DataGatewayFormLoading(),
        const DataGatewayFormDenied(),
      ],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refused read reads again once a changed answer allows read',
      setUp: () {
        access = FakeCallerAccessRepository();
        remote.onFetchOne = (_) async => throw forbidden();
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        remote.onFetchOne = (_) async => bgg;
        access.current = everything;
      },
      expect: () => [
        const DataGatewayFormLoading(),
        const DataGatewayFormDenied(),
        const DataGatewayFormLoading(),
        DataGatewayFormEditing(original: bgg, maySave: true, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refused read stays denied while a changed answer still refuses read',
      setUp: () {
        access = FakeCallerAccessRepository();
        remote.onFetchOne = (_) async => throw forbidden();
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          update: AccessExtent.all,
        );
      },
      expect: () => [
        const DataGatewayFormLoading(),
        const DataGatewayFormDenied(),
      ],
      verify: (_) => expect(remote.calls, ['fetchOne(dg_1)']),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a refused save asks access again',
      setUp: () {
        remote.onFetchOne = (_) async => bgg;
        remote.onUpdate = (_, _) async => throw forbidden();
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        bloc.add(DataGatewayFormSubmitted(input.copyWith(name: 'BGG 2')));
        await pumpEventQueue();
        expect(access.refreshCount, 1);
        // What the ask found.
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
      },
      skip: 3,
      expect: () => [
        // Says why, and still offers the save: access still allows it.
        DataGatewayFormEditing(
          original: bgg,
          maySave: true,
          accessKnown: true,
          failure: DataGatewayFormFailure.refused,
        ),
        // Access now says no, so the save goes, and the form says why in its
        // place.
        DataGatewayFormEditing(original: bgg, accessKnown: true),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'a save in flight is not interrupted by an access change',
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
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
        await pumpEventQueue();
        pending.complete(changed(bgg));
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
        const DataGatewayFormEditing(
          submitting: true,
          maySave: true,
          accessKnown: true,
        ),
        const DataGatewayFormEditing(submitting: true, accessKnown: true),
        DataGatewayFormSaved(result: changed(bgg), created: true),
      ],
      verify: (_) => expect(remote.calls, ['create(BGG)']),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an add whose create fell during its save shows access-denied if the '
      'save then fails, not the save again',
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
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
        await pumpEventQueue();
        pending.completeError(unreachable());
        await pumpEventQueue();
      },
      skip: 3,
      expect: () => [const DataGatewayFormDenied()],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'an edit whose update fell during its save does not offer the save '
      'again if the save then fails',
      setUp: () {
        pending = Completer<DataGatewayChangeResult>();
        remote
          ..onFetchOne = ((_) async => bgg)
          ..onUpdate = ((_, _) => pending.future);
      },
      build: () => editing('dg_1'),
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        bloc.add(DataGatewayFormSubmitted(input.copyWith(name: 'BGG 2')));
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
        await pumpEventQueue();
        pending.completeError(unreachable());
        await pumpEventQueue();
      },
      skip: 3,
      expect: () => [
        DataGatewayFormEditing(
          original: bgg,
          submitting: true,
          accessKnown: true,
        ),
        DataGatewayFormEditing(
          original: bgg,
          accessKnown: true,
          failure: DataGatewayFormFailure.failed,
        ),
      ],
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'sends nothing while it does not offer the save',
      setUp: () => access.current = const CallerAccess.unknown(),
      build: creating,
      act: (bloc) => bloc
        ..add(const DataGatewayFormStarted())
        ..add(const DataGatewayFormSubmitted(input)),
      verify: (_) => expect(remote.calls, isEmpty),
    );

    blocTest<DataGatewayFormBloc, DataGatewayFormState>(
      'stops listening on close',
      build: creating,
      act: (bloc) async {
        bloc.add(const DataGatewayFormStarted());
        await pumpEventQueue();
        await bloc.close();
        access.current = const CallerAccess.unknown();
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayFormEditing(maySave: true, accessKnown: true),
      ],
    );
  });
}
