import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fixtures.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;

  final read = permission('collection:read');
  final users = permission('users:manage', riskLevel: RiskLevel.critical);
  const secret = 'bge_s3cr3t_a1B2c3D4e5F6';
  final made = CreatedApiKey(apiKey: apiKey('k_new'), secret: secret);
  const transient = ApiKeyTransientException('down');
  const needsConfirmation = ApiKeyCriticalNeedsConfirmationException(
    'unconfirmed',
  );
  const picks = PickedScopes([ApiKeyScope(slug: 'collection:read')]);

  setUpAll(
    () => registerFallbackValue(
      const ApiKeyCreate(name: 'x', grant: ApiKeyEverythingGrant()),
    ),
  );

  setUp(() {
    remote = MockApiKeyRemoteDataSource();
    answerGrantable(remote, [read, users]);
    when(() => remote.create(any())).thenAnswer((_) async => made);
  });

  ApiKeyCreateBloc build() => ApiKeyCreateBloc(remote);

  /// The state once the grantable permissions have loaded.
  ApiKeyCreateState loaded([List<GrantablePermission>? grantable]) =>
      ApiKeyCreateState(
        grantableStatus: ApiKeyGrantableStatus.loaded,
        grantable: grantable ?? [read, users],
      );

  ApiKeyCreateSubmitted submitted({
    String name = 'CI deploy',
    ScopeSelection selection = picks,
    int days = 30,
    bool confirmCritical = false,
  }) => ApiKeyCreateSubmitted(
    name: name,
    selection: selection,
    days: days,
    confirmCritical: confirmCritical,
  );

  /// What the one create call was sent.
  ApiKeyCreate sent() =>
      verify(() => remote.create(captureAny())).captured.single as ApiKeyCreate;

  test('the bloc starts loading, with nothing sent and no key', () {
    final bloc = build();
    addTearDown(bloc.close);
    expect(bloc.state.grantableStatus, ApiKeyGrantableStatus.loading);
    expect(bloc.state.grantable, isEmpty);
    expect(bloc.state.submitting, isFalse);
    expect(bloc.state.failure, isNull);
    expect(bloc.state.created, isNull);
  });

  group('the grantable permissions', () {
    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'started loads grantable',
      build: build,
      act: (bloc) => bloc.add(const ApiKeyCreateStarted()),
      expect: () => [loaded()],
      verify: (_) => verify(remote.fetchGrantable).called(1),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'a failed read is a load failure, and starting again reads again',
      setUp: () {
        var calls = 0;
        when(remote.fetchGrantable).thenAnswer((_) async {
          if (calls++ == 0) throw transient;
          return [read, users];
        });
      },
      build: build,
      act: (bloc) async {
        bloc.add(const ApiKeyCreateStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyCreateStarted());
      },
      expect: () => [
        const ApiKeyCreateState(
          grantableStatus: ApiKeyGrantableStatus.loadFailed,
        ),
        const ApiKeyCreateState(),
        loaded(),
      ],
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'nothing is sent before they have loaded',
      setUp: () => when(remote.fetchGrantable).thenThrow(transient),
      build: build,
      act: (bloc) async {
        bloc.add(const ApiKeyCreateStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(submitted());
      },
      verify: (_) => verifyNever(() => remote.create(any())),
    );
  });

  group('creating', () {
    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'submitted with picks sends ApiKeyScopesGrant and the days',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted()),
      verify: (_) => expect(
        sent(),
        const ApiKeyCreate(
          name: 'CI deploy',
          grant: ApiKeyScopesGrant([ApiKeyScope(slug: 'collection:read')]),
          expiresInDays: 30,
        ),
      ),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'submitted with no picks sends an empty ApiKeyScopesGrant',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted(selection: const PickedScopes([]))),
      verify: (_) => expect(sent().grant, const ApiKeyScopesGrant([])),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'submitted with everything sends ApiKeyEverythingGrant',
      build: build,
      seed: loaded,
      act: (bloc) =>
          bloc.add(submitted(selection: const EverythingScopes(), days: 365)),
      verify: (_) => expect(
        sent(),
        const ApiKeyCreate(
          name: 'CI deploy',
          grant: ApiKeyEverythingGrant(),
          expiresInDays: 365,
        ),
      ),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'confirmCritical is sent only when the event carries it',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted(confirmCritical: true)),
      verify: (_) => expect(sent().confirmCritical, isTrue),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'success holds the created key',
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted()),
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(created: made),
      ],
      verify: (bloc) => expect(bloc.state.created?.secret, secret),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'a second submit while one is on its way is dropped',
      setUp: () {
        final answer = Completer<CreatedApiKey>();
        when(() => remote.create(any())).thenAnswer((_) => answer.future);
        addTearDown(() => answer.complete(made));
      },
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(submitted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(submitted(name: 'Another'));
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [loaded().copyWith(submitting: true)],
      verify: (_) => verify(() => remote.create(any())).called(1),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'nothing more is sent once a key has been created',
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(submitted());
        await Future<void>.delayed(Duration.zero);
        bloc
          ..add(submitted(name: 'Another'))
          ..add(const ApiKeyCreateStarted());
      },
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(created: made),
      ],
      verify: (_) {
        verify(() => remote.create(any())).called(1);
        // Reading the permissions again would take the key off the screen.
        verifyNever(remote.fetchGrantable);
      },
    );
  });

  group('refusals', () {
    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'needs recent sign-in sets that failure',
      setUp: () => when(() => remote.create(any())).thenThrow(
        const ApiKeyNeedsRecentSignInException('stale', apiMessage: 'Again.'),
      ),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted()),
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(
          failure: () => const ApiKeyFailure(
            ApiKeyFailureReason.needsRecentSignIn,
            serverMessage: 'Again.',
          ),
        ),
      ],
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'a refused scope keeps the slug the server named',
      setUp: () => when(() => remote.create(any())).thenThrow(
        const ApiKeyScopeNotGrantableException('no', slug: 'collection:read'),
      ),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted()),
      verify: (bloc) {
        expect(
          bloc.state.failure,
          const ApiKeyFailure(
            ApiKeyFailureReason.scopeNotGrantable,
            slug: 'collection:read',
          ),
        );
        expect(bloc.state.submitting, isFalse);
        expect(bloc.state.created, isNull);
      },
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'anything else thrown is a generic failure, not an uncaught error',
      setUp: () => when(
        () => remote.create(any()),
      ).thenThrow(ArgumentError('name')),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted()),
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(
          failure: () => const ApiKeyFailure(ApiKeyFailureReason.generic),
        ),
      ],
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'an unconfirmed create the server calls Critical reads the grantable '
      'permissions again, for the question to name them',
      setUp: () {
        when(() => remote.create(any())).thenThrow(needsConfirmation);
        // What the form was built from is out of date: reading again finds
        // the permission Critical.
        answerGrantable(remote, [users]);
      },
      build: build,
      seed: () => loaded([read]),
      act: (bloc) => bloc.add(submitted()),
      expect: () => [
        loaded([read]).copyWith(submitting: true),
        loaded([users]).copyWith(
          failure: () => const ApiKeyFailure(
            ApiKeyFailureReason.criticalNeedsConfirmation,
          ),
        ),
      ],
      verify: (_) => verify(remote.fetchGrantable).called(1),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'that read failing keeps the permissions it had',
      setUp: () {
        when(() => remote.create(any())).thenThrow(needsConfirmation);
        when(remote.fetchGrantable).thenThrow(transient);
      },
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted()),
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(
          failure: () => const ApiKeyFailure(
            ApiKeyFailureReason.criticalNeedsConfirmation,
          ),
        ),
      ],
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'a confirmed create the server still calls unconfirmed is a failure, '
      'and reads nothing again',
      setUp: () =>
          when(() => remote.create(any())).thenThrow(needsConfirmation),
      build: build,
      seed: loaded,
      act: (bloc) => bloc.add(submitted(confirmCritical: true)),
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(
          failure: () => const ApiKeyFailure(
            ApiKeyFailureReason.criticalNeedsConfirmation,
          ),
        ),
      ],
      verify: (_) => verifyNever(remote.fetchGrantable),
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'the next submit retires the last failure',
      setUp: () {
        var calls = 0;
        when(() => remote.create(any())).thenAnswer((_) async {
          if (calls++ == 0) throw transient;
          return made;
        });
      },
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(submitted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(submitted());
      },
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(
          failure: () => const ApiKeyFailure(ApiKeyFailureReason.transient),
        ),
        loaded().copyWith(submitting: true),
        loaded().copyWith(created: made),
      ],
    );

    blocTest<ApiKeyCreateBloc, ApiKeyCreateState>(
      'failure cleared retires the failure, and does nothing without one',
      setUp: () => when(() => remote.create(any())).thenThrow(transient),
      build: build,
      seed: loaded,
      act: (bloc) async {
        bloc.add(const ApiKeyCreateFailureCleared());
        await Future<void>.delayed(Duration.zero);
        bloc.add(submitted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyCreateFailureCleared());
      },
      expect: () => [
        loaded().copyWith(submitting: true),
        loaded().copyWith(
          failure: () => const ApiKeyFailure(ApiKeyFailureReason.transient),
        ),
        loaded(),
      ],
    );
  });

  group('the secret stays out of text', () {
    final holding = ApiKeyCreateState(
      grantableStatus: ApiKeyGrantableStatus.loaded,
      grantable: [read, users],
      created: made,
    );

    test('ApiKeyCreateState.toString hides the secret', () {
      final text = holding.toString();

      expect(text, isNot(contains(secret)));
      // It still says a key was made, and which.
      expect(text, contains('k_new'));
    });

    test('a change and a transition into it print no secret', () {
      const before = ApiKeyCreateState(submitting: true);

      expect(
        Change(currentState: before, nextState: holding).toString(),
        isNot(contains(secret)),
      );
      expect(
        Transition(
          currentState: before,
          event: submitted(),
          nextState: holding,
        ).toString(),
        isNot(contains(secret)),
      );
    });

    test('a failed expectation on the state prints no secret', () {
      // What a test runner prints when a state isn't the one expected.
      String? printed;
      try {
        expect(holding, const ApiKeyCreateState());
      } on TestFailure catch (failure) {
        printed = failure.message;
      }

      expect(printed, contains('ApiKeyCreateState('));
      expect(printed, isNot(contains(secret)));
    });

    test('no event carries or prints one', () {
      expect(submitted().toString(), isNot(contains(secret)));
      expect(submitted().props, isNot(contains(secret)));
    });
  });
}
