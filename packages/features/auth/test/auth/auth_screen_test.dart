import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/screens/auth_screen.dart';
import 'package:auth/src/widgets/login_form.dart';
import 'package:auth/src/widgets/register_form.dart';
import 'package:auth/src/widgets/oidc_strategy_button.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

const _kAuthBase = '/api/auth';

ServerIdentity _identity({
  bool hasEmailPassword = true,
  bool signUpDisabled = false,
  bool hasOidc = false,
}) => ServerIdentity(
  serverId: 'server-1',
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
    if (hasEmailPassword)
      EmailAndPasswordStrategy(
        signUpDisabled: signUpDisabled,
        signInEndpoint: '$_kAuthBase/sign-in/email',
        signUpEndpoint: signUpDisabled ? null : '$_kAuthBase/sign-up/email',
      ),
    if (hasOidc)
      const OidcStrategy(
        providerId: 'acme-sso',
        discoveryUrl: 'https://auth.acme.com/.well-known/openid-configuration',
        authorizationEndpoint: '$_kAuthBase/sign-in/oauth2',
      ),
  ],
);

// #37 i18n: AuthScreen resolves all copy from AuthLocalizations, so the
// harness must provide the delegates; assertions keep matching the
// English template values.
Widget _wrap(Widget child, MockAuthBloc bloc) => MaterialApp(
  localizationsDelegates: AuthLocalizations.localizationsDelegates,
  supportedLocales: AuthLocalizations.supportedLocales,
  home: BlocProvider<AuthBloc>.value(value: bloc, child: child),
);

AuthScreen _screen(ServerIdentity identity, MockAuthBloc bloc) =>
    AuthScreen(identity: identity, serverDisplayName: 'Test BGE Server');

void main() {
  late MockAuthBloc mockBloc;

  setUp(() {
    mockBloc = MockAuthBloc();
    when(() => mockBloc.state).thenReturn(const AuthInitial());
    when(() => mockBloc.stream).thenAnswer((_) => const Stream.empty());
  });

  group('AuthScreen', () {
    group('strategy rendering', () {
      testWidgets('shows LoginForm when server has email/password', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        expect(find.byType(LoginForm), findsOneWidget);
      });

      testWidgets('does not show LoginForm when no email strategy', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(
            _screen(_identity(hasEmailPassword: false), mockBloc),
            mockBloc,
          ),
        );

        expect(find.byType(LoginForm), findsNothing);
      });

      testWidgets('shows OIDC buttons when server has OIDC strategy', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(hasOidc: true), mockBloc), mockBloc),
        );

        expect(find.byType(OidcStrategyButton), findsOneWidget);
      });

      testWidgets('shows both forms and divider when both strategies present', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(hasOidc: true), mockBloc), mockBloc),
        );

        expect(find.byType(LoginForm), findsOneWidget);
        expect(find.byType(OidcStrategyButton), findsOneWidget);
        expect(find.text('or'), findsOneWidget);
      });

      testWidgets('shows no-strategies message when server has none', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(
            _screen(_identity(hasEmailPassword: false), mockBloc),
            mockBloc,
          ),
        );

        expect(
          find.textContaining('no authentication methods configured'),
          findsOneWidget,
        );
      });
    });

    group('sign-in/register toggle', () {
      testWidgets('switches to RegisterForm when toggle tapped', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        expect(find.byType(LoginForm), findsOneWidget);

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        expect(find.byType(RegisterForm), findsOneWidget);
        expect(find.byType(LoginForm), findsNothing);
      });

      testWidgets('switches back to LoginForm from RegisterForm', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        await tester.tap(find.text('Already have an account? Sign in'));
        await tester.pump();

        expect(find.byType(LoginForm), findsOneWidget);
      });

      testWidgets('hides register toggle when sign-up is disabled', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(signUpDisabled: true), mockBloc), mockBloc),
        );

        expect(find.text("Don't have an account? Register"), findsNothing);
      });
    });

    group('server display', () {
      testWidgets('shows server display name', (tester) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        expect(find.textContaining('Test BGE Server'), findsOneWidget);
      });
    });

    group('error handling', () {
      testWidgets('shows an inline banner on an operation failure kind', (
        tester,
      ) async {
        whenListen(
          mockBloc,
          Stream.fromIterable([
            const AuthInitial(),
            const AuthFailureInvalidCredentials(),
          ]),
          initialState: const AuthInitial(),
        );

        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );
        await tester.pumpAndSettle();

        // The screen maps the kind to the localized message.
        expect(find.text('Incorrect email or password.'), findsOneWidget);
        // In a banner, not a SnackBar: the screen stays put through a
        // failure, so the message belongs on it (#191). Asserting the
        // surface — the earlier version checked only that the copy existed,
        // which passed for any surface at all.
        expect(find.byKey(AuthScreen.failureBannerKey), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('retires the failure when the user edits a field', (
        tester,
      ) async {
        whenListen(
          mockBloc,
          Stream.fromIterable([
            const AuthInitial(),
            const AuthFailureInvalidCredentials(),
          ]),
          initialState: const AuthFailureInvalidCredentials(),
        );

        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(AuthScreen.failureBannerKey), findsOneWidget);

        await tester.enterText(
          find.byType(TextField).first,
          'someone@example.com',
        );
        await tester.pumpAndSettle();

        // Correcting the credentials the banner complains about has to
        // retire it. The banner is bound to bloc state and does not fade the
        // way the SnackBar it replaced did, so without this the user reads a
        // complaint about the value they are in the middle of replacing.
        verify(() => mockBloc.add(const AuthFailureCleared())).called(1);
      });

      testWidgets('retires the failure when the user switches modes', (
        tester,
      ) async {
        whenListen(
          mockBloc,
          Stream.fromIterable([
            const AuthInitial(),
            const AuthFailureInvalidCredentials(),
          ]),
          initialState: const AuthInitial(),
        );

        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(AuthScreen.failureBannerKey), findsOneWidget);

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        // The banner is bound to bloc state, so unlike the SnackBar it
        // replaced it does not fade. Without an explicit retirement the
        // sign-in complaint stays pinned above the *registration* form.
        verify(() => mockBloc.add(const AuthFailureCleared())).called(1);
      });
    });

    group('accessibility', () {
      testWidgets('server name has descriptive semantic label', (tester) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        final handle = tester.ensureSemantics();

        expect(
          find.bySemanticsLabel(RegExp('Server:', caseSensitive: false)),
          findsOneWidget,
        );

        handle.dispose();
      });

      testWidgets('form title is visible to screen readers', (tester) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        expect(find.text('Sign In'), findsWidgets);
      });

      testWidgets('title changes when switching to register mode', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(_identity(), mockBloc), mockBloc),
        );

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        expect(find.text('Create Account'), findsWidgets);
      });
    });
  });
}
