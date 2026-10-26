import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/screens/auth_gate.dart';
import 'package:auth/src/screens/auth_screen.dart';
import 'package:auth/src/widgets/login_form.dart';

import '../support/auth_test_fixtures.dart';

const _kSplashKey = Key('test_splash');

Widget _wrap(MockAuthBloc bloc, {String serverDisplayName = 'My Server'}) =>
    MaterialApp(
      localizationsDelegates: AuthLocalizations.localizationsDelegates,
      supportedLocales: AuthLocalizations.supportedLocales,
      home: BlocProvider<AuthBloc>.value(
        value: bloc,
        child: AuthGate(
          identity: testServerIdentity(),
          serverDisplayName: serverDisplayName,
          splash: const SizedBox(key: _kSplashKey),
        ),
      ),
    );

const _kUnreachable = AuthSessionCheckFailed(
  kind: SessionCheckFailureKind.unreachable,
);

/// Pins the #37 gate state machine: a pure function of [AuthBloc] state
/// with no widget-local memory — splash while the restore is unresolved
/// (and for the post-auth redirect microtask), a retry view saying what
/// failed for an indeterminate session check, and the form for everything
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
      await pumpWithState(tester, AuthAuthenticated(session: testSession()));

      expect(find.byKey(_kSplashKey), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
    });

    testWidgets('renders the retry view for AuthSessionCheckFailed — '
        'never the sign-in form for an indeterminate session', (tester) async {
      await pumpWithState(tester, _kUnreachable);

      expect(find.byType(SessionCheckFailedView), findsOneWidget);
      expect(find.textContaining('My Server'), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(find.byKey(_kSplashKey), findsNothing);
    });

    testWidgets('retry re-dispatches the session check', (tester) async {
      await pumpWithState(tester, _kUnreachable);

      await tester.tap(find.widgetWithText(FilledButton, 'Try Again'));
      await tester.pump();

      verify(() => mockBloc.add(const AuthSessionCheckRequested())).called(1);
    });

    // "Can't reach the server" is true of only one of the three kinds. A
    // server that answered and failed, or a fault on this device, would send
    // the user to check a connection that worked (#396).
    group('the retry view says what failed', () {
      const cases = [
        (
          SessionCheckFailureKind.unreachable,
          "Can't reach Game Night",
          'Your session could not be verified. Check your connection and try '
              'again.',
        ),
        (
          SessionCheckFailureKind.serverFault,
          "Game Night isn't working right now",
          "The server answered but couldn't check your session. Try again in "
              'a moment.',
        ),
        (
          SessionCheckFailureKind.unexpected,
          "Couldn't check your session",
          'Something went wrong on this device. Try again.',
        ),
      ];

      for (final (kind, title, body) in cases) {
        testWidgets('each kind shows its own title and body: ${kind.name}', (
          tester,
        ) async {
          when(() => mockBloc.state)
              .thenReturn(AuthSessionCheckFailed(kind: kind));
          await tester.pumpWidget(
            _wrap(mockBloc, serverDisplayName: 'Game Night'),
          );

          expect(find.text(title), findsOneWidget);
          expect(find.text(body), findsOneWidget);

          await tester.tap(find.widgetWithText(FilledButton, 'Try Again'));
          await tester.pump();
          verify(() => mockBloc.add(const AuthSessionCheckRequested()))
              .called(1);
        });
      }

      for (final kind in [
        SessionCheckFailureKind.serverFault,
        SessionCheckFailureKind.unexpected,
      ]) {
        testWidgets('only an unreachable server says to check the '
            'connection: ${kind.name}', (tester) async {
          when(() => mockBloc.state)
              .thenReturn(AuthSessionCheckFailed(kind: kind));
          await tester.pumpWidget(
            _wrap(mockBloc, serverDisplayName: 'Game Night'),
          );

          expect(find.byType(SessionCheckFailedView), findsOneWidget);
          expect(find.textContaining('connection'), findsNothing);
        });
      }
    });

    testWidgets('renders AuthScreen for AuthUnauthenticated', (tester) async {
      await pumpWithState(tester, const AuthUnauthenticated());

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byKey(_kSplashKey), findsNothing);
    });

    testWidgets("hands the shell's unsent-changes count to the sign-in screen, "
        'and its splash to hold while the count is read (#142)', (
      tester,
    ) async {
      when(() => mockBloc.state).thenReturn(const AuthUnauthenticated());
      final count = Completer<int>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AuthLocalizations.localizationsDelegates,
          supportedLocales: AuthLocalizations.supportedLocales,
          home: BlocProvider<AuthBloc>.value(
            value: mockBloc,
            child: AuthGate(
              identity: testServerIdentity(),
              serverDisplayName: 'My Server',
              splash: const SizedBox(key: _kSplashKey),
              unsentChangesCount: () => count.future,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(_kSplashKey), findsOneWidget);

      count.complete(2);
      await tester.pumpAndSettle();

      expect(find.byKey(_kSplashKey), findsNothing);
      expect(find.byKey(AuthScreen.unsentChangesNoticeKey), findsOneWidget);
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
      expect(find.byType(SessionCheckFailedView), findsNothing);
    });

    // The screen remembers a refused registration, and the gate is what
    // decides whether that memory survives: the AuthScreen element lives
    // through loading, failure and unauthenticated, and only a session check
    // (which swaps it for the splash) builds a new one (#443).
    group('a refused registration', () {
      const registerSwitch = "Don't have an account? Register";

      /// Signs up on the gate's screen and has the server refuse it, then
      /// goes back to sign-in. Returns the stream, still open, and the
      /// screen's state from before the refusal.
      Future<(StreamController<AuthBlocState>, State)> refuse(
        WidgetTester tester,
      ) async {
        final states = StreamController<AuthBlocState>();
        addTearDown(states.close);
        whenListen(
          mockBloc,
          states.stream,
          initialState: const AuthUnauthenticated(),
        );
        await tester.pumpWidget(_wrap(mockBloc));
        await tester.pumpAndSettle();
        await tester.tap(find.text(registerSwitch));
        await tester.pumpAndSettle();
        final before = tester.state(find.byType(AuthScreen));

        for (final state in const <AuthBlocState>[
          AuthLoading(),
          AuthFailureRegistrationDisabled(),
          AuthUnauthenticated(),
        ]) {
          states.add(state);
          // A frame, not a settle: loading spins until the next state.
          await tester.pump();
        }
        await tester.pumpAndSettle();
        // Below the fold once the failure banner has been up.
        final toggle = find.text('Already have an account? Sign in');
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        return (states, before);
      }

      testWidgets("a refused registration stays closed across the gate's "
          'states', (tester) async {
        final (_, before) = await refuse(tester);

        expect(find.byType(LoginForm), findsOneWidget, reason: 'sanity');
        expect(find.text(registerSwitch), findsNothing);
        expect(
          identical(tester.state(find.byType(AuthScreen)), before),
          isTrue,
          reason: 'one screen, kept through every state the gate passed',
        );
      });

      // The cached identity still says registration is open, until #87
      // refreshes it. A new screen believes it, and another attempt gets the
      // same refusal.
      testWidgets('a fresh screen after a session check offers registration '
          'again', (tester) async {
        final (states, _) = await refuse(tester);

        states.add(const AuthSessionCheckInProgress());
        await tester.pumpAndSettle();
        states.add(const AuthUnauthenticated());
        await tester.pumpAndSettle();

        expect(find.text(registerSwitch), findsOneWidget);
      });
    });

    group('SessionCheckFailedView accessibility', () {
      testWidgets('announces the failure via a live region and autofocuses '
          'retry for keyboard users', (tester) async {
        await pumpWithState(tester, _kUnreachable);
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
