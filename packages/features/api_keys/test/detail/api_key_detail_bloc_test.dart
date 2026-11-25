import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fixtures.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;

  final key = apiKey('k_1');
  final read = permission('collection:read');
  const transient = ApiKeyTransientException('down');
  const notFound = ApiKeyNotFoundException('gone');

  setUpAll(() => registerFallbackValue(const ApiKeyPatch()));

  setUp(() {
    remote = MockApiKeyRemoteDataSource();
    answerGrantable(remote, [read]);
  });

  ApiKeyDetailBloc build() => ApiKeyDetailBloc(remote, id: 'k_1');

  /// The state once [shown] and [read] have loaded.
  ApiKeyDetailState loaded([ApiKey? shown]) => ApiKeyDetailState(
    status: ApiKeyDetailStatus.loaded,
    key: shown ?? key,
    grantable: {read.slug: read},
  );

  test('the bloc starts loading, with nothing written', () {
    final bloc = build();
    addTearDown(bloc.close);
    expect(bloc.state.status, ApiKeyDetailStatus.loading);
    expect(bloc.state.key, isNull);
    expect(bloc.state.writing, isNull);
    expect(bloc.state.outcome, isNull);
    expect(bloc.state.deleted, isFalse);
  });

  group('reading', () {
    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'requested loads the key and the grantable list',
      setUp: () => answerKey(remote, key),
      build: build,
      act: (bloc) => bloc.add(const ApiKeyDetailRequested()),
      expect: () => [loaded()],
      verify: (_) {
        verify(() => remote.fetch('k_1')).called(1);
        verify(remote.fetchGrantable).called(1);
      },
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'the grantable list is read alongside the key, not after it',
      setUp: () {
        final answer = Completer<ApiKey>();
        when(() => remote.fetch('k_1')).thenAnswer((_) => answer.future);
        addTearDown(() => answer.complete(key));
      },
      build: build,
      act: (bloc) => bloc.add(const ApiKeyDetailRequested()),
      // The key has not answered, and grantable was asked for anyway.
      verify: (_) => verify(remote.fetchGrantable).called(1),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a grantable failure still loads the key, with no grantable list',
      setUp: () {
        answerKey(remote, key);
        when(remote.fetchGrantable).thenThrow(transient);
      },
      build: build,
      act: (bloc) => bloc.add(const ApiKeyDetailRequested()),
      expect: () => [
        ApiKeyDetailState(status: ApiKeyDetailStatus.loaded, key: key),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a 404 is gone',
      setUp: () => when(() => remote.fetch('k_1')).thenThrow(notFound),
      build: build,
      act: (bloc) => bloc.add(const ApiKeyDetailRequested()),
      expect: () => [const ApiKeyDetailState(status: ApiKeyDetailStatus.gone)],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'any other failure is a load failure, and asking again reads again',
      setUp: () {
        var calls = 0;
        when(() => remote.fetch('k_1')).thenAnswer((_) async {
          if (calls++ == 0) throw transient;
          return key;
        });
      },
      build: build,
      act: (bloc) async {
        bloc.add(const ApiKeyDetailRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyDetailRequested());
      },
      expect: () => [
        const ApiKeyDetailState(
          status: ApiKeyDetailStatus.loadFailed,
          loadFailure: ApiKeyFailure(ApiKeyFailureReason.transient),
        ),
        const ApiKeyDetailState(),
        loaded(),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      "a load failure keeps why, with the server's words",
      setUp: () => when(() => remote.fetch('k_1')).thenThrow(
        const ApiKeyPermanentException(
          'refused',
          statusCode: 400,
          apiMessage: 'That id is not a key id',
        ),
      ),
      build: build,
      act: (bloc) => bloc.add(const ApiKeyDetailRequested()),
      expect: () => [
        const ApiKeyDetailState(
          status: ApiKeyDetailStatus.loadFailed,
          loadFailure: ApiKeyFailure(
            ApiKeyFailureReason.generic,
            serverMessage: 'That id is not a key id',
          ),
        ),
      ],
    );
  });

  group('enabling and disabling', () {
    final disabled = key.copyWith(
      enabled: false,
      lastUsedAt: DateTime.utc(2026, 11, 24),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'enabled false sends enabled false only and takes the answered key',
      setUp: () => when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => disabled),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyEnabledChanged(enabled: false)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.toggle),
        loaded(disabled),
      ],
      verify: (_) => verify(
        () => remote.update('k_1', const ApiKeyPatch(enabled: false)),
      ).called(1),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a failed toggle keeps the old key and sets a failure',
      setUp: () => when(() => remote.update('k_1', any())).thenThrow(
        const ApiKeyPermanentException('no', apiMessage: 'Not today.'),
      ),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyEnabledChanged(enabled: false)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.toggle),
        loaded().copyWith(
          outcome: () => const ApiKeyDetailFailed(
            ApiKeyFailure(
              ApiKeyFailureReason.generic,
              serverMessage: 'Not today.',
            ),
            write: ApiKeyWrite.toggle,
          ),
        ),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a second toggle while one is in flight sends nothing',
      setUp: () {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        addTearDown(() => answer.complete(disabled));
      },
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(const ApiKeyEnabledChanged(enabled: false));
        await Future<void>.delayed(Duration.zero);
        bloc
          ..add(const ApiKeyEnabledChanged(enabled: true))
          ..add(const ApiKeyEnabledChanged(enabled: false))
          ..add(const ApiKeyDeleteRequested());
      },
      expect: () => [loaded().copyWith(writing: () => ApiKeyWrite.toggle)],
      verify: (_) {
        verify(() => remote.update('k_1', any())).called(1);
        verifyNever(() => remote.delete(any()));
      },
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'the value the key already has sends nothing',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyEnabledChanged(enabled: true)),
      expect: () => <ApiKeyDetailState>[],
      verify: (_) => verifyNever(() => remote.update(any(), any())),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a toggle starting retires the last failure',
      setUp: () => when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => disabled),
      build: build,
      seed: () => loaded().copyWith(
        outcome: () => const ApiKeyDetailFailed(
          ApiKeyFailure(ApiKeyFailureReason.transient),
          write: ApiKeyWrite.delete,
        ),
      ),
      act: (bloc) => bloc.add(const ApiKeyEnabledChanged(enabled: false)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.toggle),
        loaded(disabled),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a 404 on a toggle is gone',
      setUp: () => when(() => remote.update('k_1', any())).thenThrow(notFound),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyEnabledChanged(enabled: false)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.toggle),
        const ApiKeyDetailState(status: ApiKeyDetailStatus.gone),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'nothing is written before the key has loaded',
      build: build,
      act: (bloc) => bloc
        ..add(const ApiKeyEnabledChanged(enabled: false))
        ..add(const ApiKeyDeleteRequested()),
      expect: () => <ApiKeyDetailState>[],
      verify: (_) {
        verifyNever(() => remote.update(any(), any()));
        verifyNever(() => remote.delete(any()));
      },
    );
  });

  group('deleting', () {
    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'delete sends delete and ends deleted',
      setUp: () => when(() => remote.delete('k_1')).thenAnswer((_) async {}),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyDeleteRequested()),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.delete),
        // The key stays, so the page holds its last frame as it leaves.
        loaded().copyWith(
          deleted: true,
          outcome: () => const ApiKeyDetailDeleted(),
        ),
      ],
      verify: (_) => verify(() => remote.delete('k_1')).called(1),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a failed delete keeps the key and sets a failure',
      setUp: () => when(() => remote.delete('k_1')).thenThrow(transient),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyDeleteRequested()),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.delete),
        loaded().copyWith(
          outcome: () => const ApiKeyDetailFailed(
            ApiKeyFailure(ApiKeyFailureReason.transient),
            write: ApiKeyWrite.delete,
          ),
        ),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a 404 on a delete is gone',
      setUp: () => when(() => remote.delete('k_1')).thenThrow(notFound),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeyDeleteRequested()),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.delete),
        const ApiKeyDetailState(status: ApiKeyDetailStatus.gone),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'once deleted, nothing more is written or read',
      build: build,
      seed: () => loaded().copyWith(
        deleted: true,
        outcome: () => const ApiKeyDetailDeleted(),
      ),
      act: (bloc) => bloc
        ..add(const ApiKeyEnabledChanged(enabled: false))
        ..add(const ApiKeyDeleteRequested())
        ..add(const ApiKeyDetailRequested()),
      expect: () => <ApiKeyDetailState>[],
      verify: (_) {
        verifyNever(() => remote.update(any(), any()));
        verifyNever(() => remote.delete(any()));
        verifyNever(() => remote.fetch(any()));
      },
    );
  });

  group('saving', () {
    final renamed = key.copyWith(name: 'Renamed');
    final critical = permission('users:manage', riskLevel: RiskLevel.critical);
    const needsConfirmation = ApiKeyCriticalNeedsConfirmationException('no');
    const scopes = [
      ApiKeyScope(slug: 'collection:read'),
      ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
    ];

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a save sends only what it was given, and shows the key the server '
      'answered, saved',
      setUp: () => when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => renamed),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested(name: 'Renamed')),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        loaded(renamed).copyWith(outcome: () => const ApiKeyDetailSaved()),
      ],
      verify: (_) => verify(
        () => remote.update('k_1', const ApiKeyPatch(name: 'Renamed')),
      ).called(1),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'scopes, a new expiry and a confirmation go as they were given',
      setUp: () => when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => key),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(
        const ApiKeySaveRequested(
          scopes: scopes,
          expiresInDays: 30,
          confirmCritical: true,
        ),
      ),
      verify: (_) => verify(
        () => remote.update(
          'k_1',
          const ApiKeyPatch(
            scopes: scopes,
            expiresInDays: 30,
            confirmCritical: true,
          ),
        ),
      ).called(1),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'nothing changed sends nothing, and says there is nothing to save',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested()),
      expect: () => [
        loaded().copyWith(outcome: () => const ApiKeyDetailNothingToSave()),
      ],
      verify: (_) => verifyNever(() => remote.update(any(), any())),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a confirmation alone is nothing to save',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested(confirmCritical: true)),
      expect: () => [
        loaded().copyWith(outcome: () => const ApiKeyDetailNothingToSave()),
      ],
      verify: (_) => verifyNever(() => remote.update(any(), any())),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a failed save keeps the key as it was, and names the save',
      setUp: () => when(() => remote.update('k_1', any())).thenThrow(transient),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested(expiresInDays: 30)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        loaded().copyWith(
          outcome: () => const ApiKeyDetailFailed(
            ApiKeyFailure(ApiKeyFailureReason.transient),
            write: ApiKeyWrite.save,
          ),
        ),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'an unconfirmed save the server calls Critical reads the grantable '
      'permissions again before it fails',
      setUp: () {
        when(
          () => remote.update('k_1', any()),
        ).thenThrow(needsConfirmation);
        // What the page was built from no longer holds; now it does.
        answerGrantable(remote, [read, critical]);
      },
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested(scopes: scopes)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        loaded().copyWith(
          grantable: () => {read.slug: read, critical.slug: critical},
          outcome: () => const ApiKeyDetailFailed(
            ApiKeyFailure(ApiKeyFailureReason.criticalNeedsConfirmation),
            write: ApiKeyWrite.save,
          ),
        ),
      ],
      verify: (_) => verify(remote.fetchGrantable).called(1),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a confirmed one the server refuses the same way reads nothing again',
      setUp: () => when(
        () => remote.update('k_1', any()),
      ).thenThrow(needsConfirmation),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(
        const ApiKeySaveRequested(scopes: scopes, confirmCritical: true),
      ),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        loaded().copyWith(
          outcome: () => const ApiKeyDetailFailed(
            ApiKeyFailure(ApiKeyFailureReason.criticalNeedsConfirmation),
            write: ApiKeyWrite.save,
          ),
        ),
      ],
      verify: (_) => verifyNever(remote.fetchGrantable),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a re-read that fails keeps the permissions it had',
      setUp: () {
        when(
          () => remote.update('k_1', any()),
        ).thenThrow(needsConfirmation);
        when(remote.fetchGrantable).thenThrow(transient);
      },
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested(scopes: scopes)),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        loaded().copyWith(
          outcome: () => const ApiKeyDetailFailed(
            ApiKeyFailure(ApiKeyFailureReason.criticalNeedsConfirmation),
            write: ApiKeyWrite.save,
          ),
        ),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a 404 on a save is gone',
      setUp: () => when(() => remote.update('k_1', any())).thenThrow(notFound),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(const ApiKeySaveRequested(name: 'Renamed')),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        const ApiKeyDetailState(status: ApiKeyDetailStatus.gone),
      ],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'nothing else is written while a save is on its way',
      setUp: () {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        addTearDown(() => answer.complete(renamed));
      },
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(const ApiKeySaveRequested(name: 'Renamed'));
        await Future<void>.delayed(Duration.zero);
        bloc
          ..add(const ApiKeySaveRequested(name: 'Again'))
          ..add(const ApiKeySaveRequested())
          ..add(const ApiKeyEnabledChanged(enabled: false))
          ..add(const ApiKeyDeleteRequested());
      },
      expect: () => [loaded().copyWith(writing: () => ApiKeyWrite.save)],
      verify: (_) {
        verify(() => remote.update('k_1', any())).called(1);
        verifyNever(() => remote.delete(any()));
      },
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'no save starts while another write is on its way, or before the key '
      'has loaded',
      setUp: () {
        final answer = Completer<void>();
        when(() => remote.delete('k_1')).thenAnswer((_) => answer.future);
        addTearDown(answer.complete);
      },
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(const ApiKeyDeleteRequested());
        await Future<void>.delayed(Duration.zero);
        bloc
          ..add(const ApiKeySaveRequested(name: 'Renamed'))
          ..add(const ApiKeySaveRequested());
      },
      expect: () => [loaded().copyWith(writing: () => ApiKeyWrite.delete)],
      verify: (_) => verifyNever(() => remote.update(any(), any())),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'before the key has loaded, a save sends nothing and says nothing',
      build: build,
      act: (bloc) => bloc
        ..add(const ApiKeySaveRequested(name: 'Renamed'))
        ..add(const ApiKeySaveRequested()),
      expect: () => <ApiKeyDetailState>[],
      verify: (_) => verifyNever(() => remote.update(any(), any())),
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'a save starting retires the last outcome',
      setUp: () => when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => renamed),
      build: build,
      seed: () => loaded().copyWith(
        outcome: () => const ApiKeyDetailFailed(
          ApiKeyFailure(ApiKeyFailureReason.transient),
          write: ApiKeyWrite.toggle,
        ),
      ),
      act: (bloc) => bloc.add(const ApiKeySaveRequested(name: 'Renamed')),
      expect: () => [
        loaded().copyWith(writing: () => ApiKeyWrite.save),
        loaded(renamed).copyWith(outcome: () => const ApiKeyDetailSaved()),
      ],
    );

    test('a save names only what changed, and nothing else', () {
      expect(
        const ApiKeySaveRequested(name: 'Renamed'),
        const ApiKeySaveRequested(name: 'Renamed'),
      );
      expect(
        const ApiKeySaveRequested(scopes: scopes),
        ApiKeySaveRequested(scopes: List.of(scopes)),
      );
      expect(
        const ApiKeySaveRequested(name: 'Renamed'),
        isNot(
          const ApiKeySaveRequested(name: 'Renamed', confirmCritical: true),
        ),
      );
    });
  });

  group('outcomes', () {
    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'outcome cleared retires a failure',
      build: build,
      seed: () => loaded().copyWith(
        outcome: () => const ApiKeyDetailFailed(
          ApiKeyFailure(ApiKeyFailureReason.transient),
          write: ApiKeyWrite.toggle,
        ),
      ),
      act: (bloc) => bloc.add(const ApiKeyDetailOutcomeCleared()),
      expect: () => [loaded()],
    );

    blocTest<ApiKeyDetailBloc, ApiKeyDetailState>(
      'outcome cleared retires saved and nothing to save too',
      build: build,
      seed: () => loaded().copyWith(outcome: () => const ApiKeyDetailSaved()),
      act: (bloc) => bloc
        ..add(const ApiKeyDetailOutcomeCleared())
        ..add(const ApiKeySaveRequested())
        ..add(const ApiKeyDetailOutcomeCleared()),
      expect: () => [
        loaded(),
        loaded().copyWith(outcome: () => const ApiKeyDetailNothingToSave()),
        loaded(),
      ],
    );

    test('a failure says which write failed and why, and nothing else', () {
      const failed = ApiKeyDetailFailed(
        ApiKeyFailure(ApiKeyFailureReason.transient),
        write: ApiKeyWrite.delete,
      );
      expect(
        failed,
        const ApiKeyDetailFailed(
          ApiKeyFailure(ApiKeyFailureReason.transient),
          write: ApiKeyWrite.delete,
        ),
      );
      expect(
        failed,
        isNot(
          const ApiKeyDetailFailed(
            ApiKeyFailure(ApiKeyFailureReason.transient),
            write: ApiKeyWrite.toggle,
          ),
        ),
      );
    });
  });
}
