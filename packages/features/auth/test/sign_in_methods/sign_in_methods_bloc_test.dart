import 'dart:async';

import 'package:auth/src/sign_in_methods/sign_in_method_rows.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_bloc.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_event.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_state.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/auth_test_fixtures.dart';

OidcStrategy _strategy(String id, [String? name]) => OidcStrategy(
  providerId: id,
  displayName: name ?? id,
  discoveryUrl: 'https://example.test/$id/.well-known',
  authorizationEndpoint: '/auth/$id',
  appSignInEndpoint: '/app/$id',
  appTokenEndpoint: '/token/$id',
);

SignInMethod _method(String id, String providerId) =>
    SignInMethod(id: id, providerId: providerId);

final SignInMethod _password = _method('pw', SignInMethod.passwordProviderId);
final SignInMethod _authentik = _method('row-a', 'authentik');
final List<OidcStrategy> _strategies = [
  _strategy('authentik', 'Authentik'),
  _strategy('google', 'Google'),
];

void main() {
  late MockAuthRepository repo;

  setUpAll(() => registerFallbackValue(_strategies.first));

  setUp(() {
    repo = MockAuthRepository();
    when(() => repo.providerLinkSupported).thenReturn(true);
    when(() => repo.takeProviderLinkReturn()).thenReturn(null);
    when(() => repo.listSignInMethods()).thenAnswer((_) async => [_password]);
  });

  SignInMethodsBloc build({bool passwordSignInOffered = true}) =>
      SignInMethodsBloc(
        repository: repo,
        strategies: _strategies,
        passwordSignInOffered: passwordSignInOffered,
        returnPath: '/settings/sign-in-methods',
      );

  SignInMethodsState loaded(
    List<SignInMethod> methods, {
    SignInMethodsOutcome? outcome,
    String? unlinkingId,
    String? linkingProviderId,
    bool passwordSignInOffered = true,
  }) {
    final d = describeSignInMethods(
      methods,
      _strategies,
      passwordSignInOffered: passwordSignInOffered,
    );
    return SignInMethodsState(
      status: SignInMethodsStatus.loaded,
      linkSupported: true,
      rows: d.rows,
      linkable: d.linkable,
      outcome: outcome,
      unlinkingId: unlinkingId,
      linkingProviderId: linkingProviderId,
    );
  }

  const loading = SignInMethodsState(
    status: SignInMethodsStatus.loading,
    linkSupported: true,
  );

  group('SignInMethodsBloc', () {
    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'loads the methods',
      build: build,
      act: (b) => b.add(const SignInMethodsRequested()),
      // A bloc's first emit is not deduped, so loading shows once.
      expect: () => [
        loading,
        loaded([_password]),
      ],
    );

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'a password the server no longer offers is no way in',
      setUp: () => when(
        () => repo.listSignInMethods(),
      ).thenAnswer((_) async => [_password, _authentik]),
      build: () => build(passwordSignInOffered: false),
      act: (b) => b.add(const SignInMethodsRequested()),
      skip: 1,
      expect: () => [
        loaded([_password, _authentik], passwordSignInOffered: false),
      ],
      verify: (b) => expect(b.state.rows[1].unlinkIsLastWayIn, isTrue),
    );

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'reads linkSupported from the repository',
      setUp: () => when(() => repo.providerLinkSupported).thenReturn(false),
      build: build,
      verify: (b) => expect(b.state.linkSupported, isFalse),
    );

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'the startup link return becomes SignInMethodLinked',
      setUp: () => when(() => repo.takeProviderLinkReturn()).thenReturn(
        const ProviderLinkSucceeded('authentik'),
      ),
      build: build,
      act: (b) => b.add(const SignInMethodsRequested()),
      expect: () => [
        loading.copyWith(outcome: () => const SignInMethodLinked('authentik')),
        loaded([_password], outcome: const SignInMethodLinked('authentik')),
      ],
    );

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'a failed startup link return becomes SignInMethodLinkFailed',
      setUp: () => when(() => repo.takeProviderLinkReturn()).thenReturn(
        const ProviderLinkFailed(
          'authentik',
          AuthProviderLinkException(ProviderLinkFailureReason.accessDenied),
        ),
      ),
      build: build,
      act: (b) => b.add(const SignInMethodsRequested()),
      skip: 1,
      expect: () => [
        loaded(
          [_password],
          outcome: const SignInMethodLinkFailed(
            'authentik',
            ProviderLinkFailureReason.accessDenied,
          ),
        ),
      ],
    );

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'takes the link return on the first request only',
      build: build,
      act: (b) async {
        b.add(const SignInMethodsRequested());
        await b.stream.firstWhere(
          (s) => s.status == SignInMethodsStatus.loaded,
        );
        b.add(const SignInMethodsRequested());
      },
      verify: (_) => verify(() => repo.takeProviderLinkReturn()).called(1),
    );

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'a failed load is loadFailed, and a request retries it',
      setUp: () {
        var calls = 0;
        when(() => repo.listSignInMethods()).thenAnswer((_) async {
          if (calls++ == 0) {
            throw const AuthNetworkException(message: 'offline');
          }
          return [_password];
        });
      },
      build: build,
      act: (b) async {
        b.add(const SignInMethodsRequested());
        await b.stream.firstWhere(
          (s) => s.status == SignInMethodsStatus.loadFailed,
        );
        b.add(const SignInMethodsRequested());
      },
      expect: () => [
        loading,
        loading.copyWith(status: SignInMethodsStatus.loadFailed),
        loading,
        loaded([_password]),
      ],
    );

    group('link', () {
      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'sets and clears linkingProviderId, with no outcome when the page '
        'stayed',
        setUp: () => when(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).thenAnswer((_) async {}),
        build: build,
        seed: () => loaded([_password]),
        act: (b) => b.add(SignInMethodLinkRequested(_strategies.first)),
        expect: () => [
          loaded([_password], linkingProviderId: 'authentik'),
          loaded([_password]),
        ],
        verify: (_) => verify(
          () => repo.linkProvider(
            _strategies.first,
            returnPath: '/settings/sign-in-methods',
          ),
        ).called(1),
      );

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a second link while one is out is dropped',
        setUp: () {
          final gate = Completer<void>();
          when(
            () =>
                repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
          ).thenAnswer((_) => gate.future);
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
        },
        build: build,
        seed: () => loaded([_password]),
        act: (b) async {
          b
            ..add(SignInMethodLinkRequested(_strategies[0]))
            ..add(SignInMethodLinkRequested(_strategies[1]));
          await Future<void>.delayed(Duration.zero);
        },
        expect: () => [
          loaded([_password], linkingProviderId: 'authentik'),
        ],
        verify: (_) => verify(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).called(1),
      );

      for (final (name, error, expected)
          in <(String, Exception, SignInMethodLinkFailed)>[
            (
              'the 403 becomes needsRecentSignIn',
              const AuthProviderLinkException(
                ProviderLinkFailureReason.needsRecentSignIn,
              ),
              const SignInMethodLinkFailed(
                'authentik',
                ProviderLinkFailureReason.needsRecentSignIn,
              ),
            ),
            (
              'a rate limit carries retryAfter',
              const AuthRateLimitedException(retryAfter: Duration(seconds: 7)),
              const SignInMethodLinkFailed(
                'authentik',
                ProviderLinkFailureReason.rateLimited,
                retryAfter: Duration(seconds: 7),
              ),
            ),
            (
              'a network failure becomes network',
              const AuthNetworkException(message: 'offline'),
              const SignInMethodLinkFailed(
                'authentik',
                ProviderLinkFailureReason.network,
              ),
            ),
            (
              'a server failure becomes generic',
              const AuthServerException(message: 'bad'),
              const SignInMethodLinkFailed(
                'authentik',
                ProviderLinkFailureReason.generic,
              ),
            ),
            (
              'a plain Exception becomes generic and does not escape',
              Exception('boom'),
              const SignInMethodLinkFailed(
                'authentik',
                ProviderLinkFailureReason.generic,
              ),
            ),
          ]) {
        blocTest<SignInMethodsBloc, SignInMethodsState>(
          name,
          setUp: () => when(
            () =>
                repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
          ).thenThrow(error),
          build: build,
          seed: () => loaded([_password]),
          act: (b) => b.add(SignInMethodLinkRequested(_strategies.first)),
          skip: 1,
          expect: () => [
            loaded([_password], outcome: expected),
          ],
        );
      }

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a superseded link clears linkingProviderId with no outcome',
        setUp: () => when(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).thenThrow(const AuthSupersededException()),
        build: build,
        seed: () => loaded([_password]),
        act: (b) => b.add(SignInMethodLinkRequested(_strategies.first)),
        expect: () => [
          loaded([_password], linkingProviderId: 'authentik'),
          loaded([_password]),
        ],
      );

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'starting a link retires the previous outcome',
        setUp: () => when(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).thenAnswer((_) async {}),
        build: build,
        seed: () => loaded(
          [_password],
          outcome: const SignInMethodUnlinkFailed(
            ProviderLinkFailureReason.generic,
          ),
        ),
        act: (b) => b.add(SignInMethodLinkRequested(_strategies.first)),
        expect: () => [
          loaded([_password], linkingProviderId: 'authentik'),
          loaded([_password]),
        ],
      );

      for (final (name, finish) in <(String, void Function(Completer<void>))>[
        ('completes', (g) => g.complete()),
        (
          'fails',
          (g) => g.completeError(const AuthNetworkException(message: 'x')),
        ),
      ]) {
        // A pop on web can close the bloc while linkProvider waits out its
        // page-leave grace. Finishing afterwards must raise nothing: an
        // escaped error would open the crash prompt. The test fails on any
        // uncaught error.
        test('closing the bloc while a link is out, then it $name', () async {
          final gate = Completer<void>();
          when(
            () =>
                repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
          ).thenAnswer((_) => gate.future);
          final b = build()
            ..emit(loaded([_password]))
            ..add(SignInMethodLinkRequested(_strategies.first));
          await Future<void>.delayed(Duration.zero);
          verify(
            () => repo.linkProvider(
              any(),
              returnPath: any(named: 'returnPath'),
            ),
          ).called(1);
          await b.close();
          finish(gate);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
    });

    group('unlink', () {
      final row = describeSignInMethods(
        [_password, _authentik],
        _strategies,
        passwordSignInOffered: true,
      ).rows[1];

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a successful unlink reloads and sets SignInMethodUnlinked',
        setUp: () {
          when(
            () => repo.unlinkSignInMethod(any()),
          ).thenAnswer((_) async {});
          when(
            () => repo.listSignInMethods(),
          ).thenAnswer((_) async => [_password]);
        },
        build: build,
        seed: () => loaded([_password, _authentik]),
        act: (b) => b.add(SignInMethodUnlinkRequested(row)),
        expect: () => [
          loaded([_password, _authentik], unlinkingId: 'row-a'),
          loaded([_password], outcome: SignInMethodUnlinked(row.label)),
        ],
        verify: (_) {
          verify(() => repo.unlinkSignInMethod('row-a')).called(1);
          verify(() => repo.listSignInMethods()).called(1);
        },
      );

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a reload that fails keeps the outcome and drops the row locally',
        setUp: () {
          when(
            () => repo.unlinkSignInMethod(any()),
          ).thenAnswer((_) async {});
          when(
            () => repo.listSignInMethods(),
          ).thenAnswer((_) async => [_password, _authentik]);
        },
        build: build,
        act: (b) async {
          b.add(const SignInMethodsRequested());
          await b.stream.firstWhere(
            (s) => s.status == SignInMethodsStatus.loaded,
          );
          when(
            () => repo.listSignInMethods(),
          ).thenThrow(const AuthNetworkException(message: 'offline'));
          b.add(SignInMethodUnlinkRequested(row));
        },
        skip: 3,
        expect: () => [
          loaded([_password], outcome: SignInMethodUnlinked(row.label)),
        ],
      );

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a refused unlink sets SignInMethodUnlinkFailed',
        setUp: () => when(() => repo.unlinkSignInMethod(any())).thenThrow(
          const AuthProviderLinkException(
            ProviderLinkFailureReason.lastSignInMethod,
          ),
        ),
        build: build,
        seed: () => loaded([_password, _authentik]),
        act: (b) => b.add(SignInMethodUnlinkRequested(row)),
        skip: 1,
        expect: () => [
          loaded(
            [_password, _authentik],
            outcome: const SignInMethodUnlinkFailed(
              ProviderLinkFailureReason.lastSignInMethod,
            ),
          ),
        ],
      );

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a second unlink while one is out is dropped',
        setUp: () {
          final gate = Completer<void>();
          when(
            () => repo.unlinkSignInMethod(any()),
          ).thenAnswer((_) => gate.future);
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
        },
        build: build,
        seed: () => loaded([_password, _authentik]),
        act: (b) async {
          b
            ..add(SignInMethodUnlinkRequested(row))
            ..add(SignInMethodUnlinkRequested(row));
          await Future<void>.delayed(Duration.zero);
        },
        expect: () => [
          loaded([_password, _authentik], unlinkingId: 'row-a'),
        ],
        verify: (_) => verify(() => repo.unlinkSignInMethod(any())).called(1),
      );

      blocTest<SignInMethodsBloc, SignInMethodsState>(
        'a rate-limited unlink carries retryAfter',
        setUp: () => when(() => repo.unlinkSignInMethod(any())).thenThrow(
          const AuthRateLimitedException(retryAfter: Duration(seconds: 3)),
        ),
        build: build,
        seed: () => loaded([_password, _authentik]),
        act: (b) => b.add(SignInMethodUnlinkRequested(row)),
        skip: 1,
        expect: () => [
          loaded(
            [_password, _authentik],
            outcome: const SignInMethodUnlinkFailed(
              ProviderLinkFailureReason.rateLimited,
              retryAfter: Duration(seconds: 3),
            ),
          ),
        ],
      );
    });

    blocTest<SignInMethodsBloc, SignInMethodsState>(
      'SignInMethodsOutcomeCleared retires the outcome',
      build: build,
      seed: () => loaded(
        [_password],
        outcome: const SignInMethodLinked('authentik'),
      ),
      act: (b) => b.add(const SignInMethodsOutcomeCleared()),
      expect: () => [
        loaded([_password]),
      ],
    );
  });
}
