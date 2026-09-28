import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/screens/auth_screen.dart';
import 'package:auth/src/widgets/login_form.dart';
import 'package:auth/src/widgets/register_form.dart';
import 'package:auth/src/widgets/oidc_strategy_button.dart';

import '../support/auth_test_fixtures.dart';

// #37 i18n: AuthScreen resolves all copy from AuthLocalizations, so the
// harness must provide the delegates; assertions keep matching the
// English template values.
Widget _wrap(Widget child, MockAuthBloc bloc) => MaterialApp(
  theme: BgeTheme.light(),
  localizationsDelegates: AuthLocalizations.localizationsDelegates,
  supportedLocales: AuthLocalizations.supportedLocales,
  home: BlocProvider<AuthBloc>.value(value: bloc, child: child),
);

AuthScreen _screen(ServerIdentity identity) =>
    AuthScreen(identity: identity, serverDisplayName: 'Test BGE Server');

/// Sets the render surface to a small window. `MediaQueryData.size` is metadata
/// and constrains nothing, so the viewport the banner has to be revealed within
/// has to come from the view.
///
/// 400dp tall rather than the checklist's 480: at 200% text scale this screen
/// overflows a 480dp viewport by only ~8dp, so a regression test pinned there
/// would reproduce #209 by a margin that any copy or spacing change could
/// erase, and would then pass while testing nothing. Desktop and browser are
/// first-class targets, so a window this short is a real one.
void _useNarrowWindow(WidgetTester tester) {
  useViewSize(tester, const Size(320, 400));
}

/// The failure banner's top edge in the page scroll viewport's own space.
///
/// Geometry rather than `findsOneWidget`, which passes for a banner scrolled
/// clean out of the viewport — the bug in #209, and the reason no existing
/// assertion in this file could catch it.
double _bannerTop(WidgetTester tester) =>
    topInViewport(tester, find.byKey(AuthScreen.failureBannerKey));

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
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

        expect(find.byType(LoginForm), findsOneWidget);
      });

      testWidgets('does not show LoginForm when no email strategy', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(testServerIdentity(hasEmailPassword: false)), mockBloc),
        );

        expect(find.byType(LoginForm), findsNothing);
      });

      testWidgets('shows OIDC buttons when server has OIDC strategy', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(testServerIdentity(hasOidc: true)), mockBloc),
        );

        expect(find.byType(OidcStrategyButton), findsOneWidget);
      });

      testWidgets('shows both forms and divider when both strategies present', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(testServerIdentity(hasOidc: true)), mockBloc),
        );

        expect(find.byType(LoginForm), findsOneWidget);
        expect(find.byType(OidcStrategyButton), findsOneWidget);
        expect(find.text('or'), findsOneWidget);
      });

      testWidgets('shows no-strategies message when server has none', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_screen(testServerIdentity(hasEmailPassword: false)), mockBloc),
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
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

        expect(find.byType(LoginForm), findsOneWidget);

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        expect(find.byType(RegisterForm), findsOneWidget);
        expect(find.byType(LoginForm), findsNothing);
      });

      testWidgets('switches back to LoginForm from RegisterForm', (
        tester,
      ) async {
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

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
          _wrap(_screen(testServerIdentity(signUpDisabled: true)), mockBloc),
        );

        expect(find.text("Don't have an account? Register"), findsNothing);
      });
    });

    group('server display', () {
      testWidgets('shows server display name', (tester) async {
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

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

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
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

      testWidgets('a reply this device could not decode does not blame the '
          'connection (#357)', (tester) async {
        whenListen(
          mockBloc,
          Stream.fromIterable([
            const AuthInitial(),
            const AuthFailureLocalDecode(),
          ]),
          initialState: const AuthInitial(),
        );

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
        await tester.pumpAndSettle();

        // The server answered; only this device failed to read the reply.
        expect(
          find.text(
            'This device could not read the server\'s reply. Please '
            'try again.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Could not reach the server. Check your connection.'),
          findsNothing,
        );
      });

      // The copy asserts neither that an account was created nor why: a
      // duplicate sign-up on a verification-required server gets the same
      // envelope as a new one (#331).
      testWidgets('a session the server did not grant says so, without '
          'calling it a server fault (#331)', (tester) async {
        whenListen(
          mockBloc,
          Stream.fromIterable([
            const AuthInitial(),
            const AuthFailureSessionNotGranted(),
          ]),
          initialState: const AuthInitial(),
        );

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
        await tester.pumpAndSettle();

        expect(
          find.text(
            "This server accepted your details but didn't sign you in. It "
            'may need you to confirm your email first — check your inbox, '
            'then sign in.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Something went wrong on the server. Please try again.'),
          findsNothing,
        );
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

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
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

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
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
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

        final handle = tester.ensureSemantics();

        expect(
          find.bySemanticsLabel(RegExp('Server:', caseSensitive: false)),
          findsOneWidget,
        );

        handle.dispose();
      });

      testWidgets('form title is visible to screen readers', (tester) async {
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

        expect(find.text('Sign In'), findsWidgets);
      });

      testWidgets('title changes when switching to register mode', (
        tester,
      ) async {
        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        expect(find.text('Create Account'), findsWidgets);
      });
    });

    group('rejected submit (#230)', () {
      testWidgets('a rejected sign-in brings its first error into view and '
          'focuses it, on a small window at 200% text scale', (tester) async {
        // Measured before `rejectSubmit`: at 320x400 the first error sat 5dp
        // above the viewport after a tap on "Sign In" with the form empty.
        _useNarrowWindow(tester);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _wrap(_screen(testServerIdentity()), mockBloc),
          ),
        );
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        final position = pageScrollOf(tester).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
        await tester.pumpAndSettle();

        final email = find.byType(EditableText).first;
        expect(tester.widget<EditableText>(email).focusNode.hasFocus, isTrue);
        final errorTop = topInViewport(
          tester,
          find.text('This field is required').first,
        );
        expect(errorTop, greaterThanOrEqualTo(0));
        expect(errorTop, lessThan(scrollViewportOf(tester).size.height));
      });

      testWidgets('a rejected register brings its first error into view and '
          'focuses it, on a small window at 200% text scale', (tester) async {
        // Measured before `rejectSubmit`: a user who scrolled down to reach
        // "Create Account" and tapped it with the form empty was left with the
        // first error 145dp above the viewport — a button that did nothing.
        useViewSize(tester, const Size(320, 480));
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _wrap(_screen(testServerIdentity()), mockBloc),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.text("Don't have an account? Register");
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        // Autofocus put the caret in the email field; a user who scrolled and
        // tapped the button has moved off it.
        FocusManager.instance.primaryFocus?.unfocus();
        final position = pageScrollOf(tester).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Create Account'));
        await tester.pumpAndSettle();

        final email = find.byType(EditableText).first;
        expect(tester.widget<EditableText>(email).focusNode.hasFocus, isTrue);
        final errorTop = topInViewport(
          tester,
          find.text('This field is required').first,
        );
        expect(errorTop, greaterThanOrEqualTo(0));
        expect(errorTop, lessThan(scrollViewportOf(tester).size.height));
      });
    });

    group('failure placement (#209, #211)', () {
      /// Pumps the screen at 320x400 and 200% text with the failure stream
      /// under the test's control, so a failure can land after the user has
      /// moved. Returns the stream.
      Future<StreamController<AuthBlocState>> pumpSmall(
        WidgetTester tester, {
        bool register = false,
      }) async {
        _useNarrowWindow(tester);
        final states = StreamController<AuthBlocState>();
        addTearDown(states.close);
        whenListen(mockBloc, states.stream, initialState: const AuthInitial());
        await tester.pumpWidget(
          MediaQuery(
            // Above MaterialApp on purpose: `MediaQuery.fromView` is inserted
            // by `View`, higher still, so this one wins for the subtree below.
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _wrap(_screen(testServerIdentity()), mockBloc),
          ),
        );
        await tester.pumpAndSettle();
        if (register) {
          final toggle = find.text("Don't have an account? Register");
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
        }
        return states;
      }

      testWidgets('a failure after the user scrolled to the submit lands on '
          'it, with the submit starting in view beneath', (tester) async {
        // #209's scenario. The banner used to sit at the top of the page, so
        // answering this tap scrolled the user away from the button they
        // pressed: measured, the submit's top edge ended at 474 in this 400dp
        // viewport, wholly below the window. Above the submit, it starts at
        // 386. Not wholly in view — at 200% text the titled banner and the
        // button together are taller than this window — but the answer and
        // the thing it answers are now read together.
        final states = await pumpSmall(tester);
        final position = pageScrollOf(tester).position;
        expect(
          position.maxScrollExtent,
          greaterThan(0),
          reason:
              'sanity: at 200% scale this screen must overflow the '
              'viewport, or there is nothing to scroll to',
        );
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();

        states.add(const AuthFailureInvalidCredentials());
        await tester.pumpAndSettle();

        final banner = tester.getRect(find.byKey(AuthScreen.failureBannerKey));
        final submit = tester.getRect(find.byType(FilledButton).first);
        expect(
          _bannerTop(tester),
          moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        );
        expect(submit.top - banner.bottom, BgeTokens.standard.spaceMd);
        expect(
          topInViewport(tester, find.byType(FilledButton).first),
          lessThan(scrollViewportOf(tester).size.height),
          reason: 'the button the failure answers starts in view',
        );
      });

      testWidgets('a failure submitted from the keyboard at the top of the '
          'page is revealed below it', (tester) async {
        // The other direction: the password field's "done" action submits
        // without the user ever scrolling to the button, so the banner above
        // the submit arrives below the viewport.
        final states = await pumpSmall(tester);
        expect(pageScrollOf(tester).position.pixels, 0, reason: 'sanity');

        states.add(const AuthFailureInvalidCredentials());
        await tester.pumpAndSettle();

        expect(
          _bannerTop(tester),
          moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
          reason:
              'the banner leads with its top edge, one spacing step below '
              'the viewport start so it is not flush against the window edge',
        );
      });
    });

    group('failure title (#211)', () {
      testWidgets('a sign-in failure is titled with the operation', (
        tester,
      ) async {
        whenListen(
          mockBloc,
          Stream.fromIterable([
            const AuthInitial(),
            const AuthFailureNetwork(),
          ]),
          initialState: const AuthInitial(),
        );

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
        await tester.pumpAndSettle();

        // "Could not reach the server" never says that signing in failed.
        final banner = find.byKey(AuthScreen.failureBannerKey);
        expect(
          find.descendant(of: banner, matching: find.text("Couldn't sign in")),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: banner,
            matching: find.text(
              'Could not reach the server. Check your connection.',
            ),
          ),
          findsOneWidget,
        );
      });

      testWidgets('a registration failure is titled with its own operation', (
        tester,
      ) async {
        final states = StreamController<AuthBlocState>();
        addTearDown(states.close);
        whenListen(mockBloc, states.stream, initialState: const AuthInitial());

        await tester.pumpWidget(_wrap(_screen(testServerIdentity()), mockBloc));
        await tester.pumpAndSettle();
        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pumpAndSettle();
        states.add(const AuthFailureNetwork());
        await tester.pumpAndSettle();

        final banner = find.byKey(AuthScreen.failureBannerKey);
        expect(
          find.descendant(
            of: banner,
            matching: find.text("Couldn't create account"),
          ),
          findsOneWidget,
        );
        expect(find.text("Couldn't sign in"), findsNothing);
      });
    });

    group('failure across a mode switch (#211)', () {
      testWidgets('a sign-in failure never renders in the registration form, '
          'not even for a frame', (tester) async {
        // The banner lives in each form now, so a switch unmounts one and
        // mounts the other. A failure still in the bloc when the registration
        // form first builds would render there under "Couldn't create
        // account", and announce itself as new. A real bloc, because the
        // mock only records that the clear was dispatched — what matters is
        // that it lands before the next frame.
        final repo = MockAuthRepository();
        when(repo.watchAuthState).thenAnswer((_) => const Stream.empty());
        when(
          () => repo.signIn(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenThrow(const AuthInvalidCredentialsException());
        await tester.pumpWidget(
          MaterialApp(
            theme: BgeTheme.light(),
            localizationsDelegates: AuthLocalizations.localizationsDelegates,
            supportedLocales: AuthLocalizations.supportedLocales,
            // `create`, as the router provides it: the provider closes the
            // bloc when the tree goes, without the test awaiting a close
            // that never settles under the fake-async zone.
            home: BlocProvider<AuthBloc>(
              create: (_) => AuthBloc(authRepository: repo),
              child: _screen(testServerIdentity()),
            ),
          ),
        );
        await tester.enterText(
          find.byType(TextField).at(0),
          'someone@example.com',
        );
        await tester.enterText(find.byType(TextField).at(1), 'wrong');
        await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
        await tester.pumpAndSettle();
        expect(find.byKey(AuthScreen.failureBannerKey), findsOneWidget);

        await tester.tap(find.text("Don't have an account? Register"));
        await tester.pump();

        expect(find.byType(RegisterForm), findsOneWidget, reason: 'sanity');
        expect(find.byKey(AuthScreen.failureBannerKey), findsNothing);
      });
    });
  });
}
