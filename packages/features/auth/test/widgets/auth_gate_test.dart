import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/screens/auth_gate.dart';
import 'package:auth/src/screens/auth_screen.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

const _kSplashKey = Key('test_splash');
const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [
    const EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

AuthResponse _session() => AuthResponse(
  token: 'tok-abc',
  user: AuthUser(
    id: 'u1',
    username: 'testuser',
    email: 'u1@example.com',
    emailVerified: true,
    createdAt: DateTime(2099),
    updatedAt: DateTime(2099),
  ),
  expiresAt: DateTime(2099).toUtc(),
);

Widget _wrap(MockAuthBloc bloc) => MaterialApp(
  localizationsDelegates: AuthLocalizations.localizationsDelegates,
  supportedLocales: AuthLocalizations.supportedLocales,
  home: BlocProvider<AuthBloc>.value(
    value: bloc,
    child: AuthGate(
      identity: _identity(),
      serverDisplayName: 'My Server',
      splash: const SizedBox(key: _kSplashKey),
    ),
  ),
);

/// Pins the #37 gate state machine: a pure function of [AuthBloc] state
/// with no widget-local memory — splash while the restore is unresolved
/// (and for the post-auth redirect microtask), a retryable unreachable
/// view for an indeterminate session check, and the form for everything
/// interactive. The sign-in form must NEVER appear during the restore
/// phase (the no-flicker requirement).
void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSessionCheckRequested());
    registerFallbackValue(const AuthInitial());
  });

  late MockAuthBloc mockBloc;

  setUp(() {
    mockBloc = MockAuthBloc();
  });

  Future<void> pumpWithState(WidgetTester tester, AuthBlocState state) async {
    when(() => mockBloc.state).thenReturn(state);
    await tester.pumpWidget(_wrap(mockBloc));
  }

  group('AuthGate', () {
    testWidgets('renders splash for AuthInitial — no form flash', (
      tester,
    ) async {
      await pumpWithState(tester, const AuthInitial());

      expect(find.byKey(_kSplashKey), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
    });

    testWidgets('renders splash while the session check is in flight', (
      tester,
    ) async {
      await pumpWithState(tester, const AuthSessionCheckInProgress());

      expect(find.byKey(_kSplashKey), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
    });

    testWidgets('renders splash for AuthAuthenticated — the router is about '
        'to redirect; the gate holds splash for the microtask', (tester) async {
      await pumpWithState(tester, AuthAuthenticated(session: _session()));

      expect(find.byKey(_kSplashKey), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
    });

    testWidgets('renders the unreachable view for AuthSessionCheckFailed — '
        'never the sign-in form for an indeterminate session', (tester) async {
      await pumpWithState(tester, const AuthSessionCheckFailed());

      expect(find.byType(SessionUnreachableView), findsOneWidget);
      expect(find.textContaining('My Server'), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(find.byKey(_kSplashKey), findsNothing);
    });

    testWidgets('retry re-dispatches the session check', (tester) async {
      await pumpWithState(tester, const AuthSessionCheckFailed());

      await tester.tap(find.widgetWithText(FilledButton, 'Try Again'));
      await tester.pump();

      verify(() => mockBloc.add(const AuthSessionCheckRequested())).called(1);
    });

    testWidgets('renders AuthScreen for AuthUnauthenticated', (tester) async {
      await pumpWithState(tester, const AuthUnauthenticated());

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byKey(_kSplashKey), findsNothing);
    });

    testWidgets('renders AuthScreen (not splash) for interactive '
        'AuthLoading — the form owns its own progress', (tester) async {
      await pumpWithState(tester, const AuthLoading());

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byKey(_kSplashKey), findsNothing);
    });

    testWidgets('renders AuthScreen for an interactive failure kind — the '
        'form stays up with its live-region snack bar', (tester) async {
      await pumpWithState(tester, const AuthFailureInvalidCredentials());

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(SessionUnreachableView), findsNothing);
    });

    group('SessionUnreachableView accessibility', () {
      testWidgets('announces the failure via a live region and autofocuses '
          'retry for keyboard users', (tester) async {
        await pumpWithState(tester, const AuthSessionCheckFailed());
        final handle = tester.ensureSemantics();
        await tester.pump();

        expect(
          find.bySemanticsLabel(RegExp('Try Again', caseSensitive: false)),
          findsWidgets,
        );
        final button = tester.widget<FilledButton>(find.byType(FilledButton));
        expect(button.autofocus, isTrue);

        handle.dispose();
      });
    });
  });
}
