import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/screens/auth_screen.dart';
import 'package:auth/src/widgets/login_form.dart';
import 'package:auth/src/widgets/oidc_strategy_button.dart';
import 'package:auth/src/widgets/register_form.dart';

import '../support/auth_test_fixtures.dart';

/// A second provider, for what a press on one does to the other.
const _keycloak = OidcStrategy(
  providerId: 'keycloak',
  discoveryUrl: 'https://sso.acme.com/.well-known/openid-configuration',
  displayName: 'Keycloak',
  authorizationEndpoint: '/api/auth/sign-in/social',
  appSignInEndpoint: '/api/auth/app-sign-in/start',
  appTokenEndpoint: '/api/auth/app-sign-in/token',
);

/// A display name long enough to wrap at 320dp and 2.0 text.
const _longName = OidcStrategy(
  providerId: 'corp-sso',
  discoveryUrl: 'https://sso.corp.example/.well-known/openid-configuration',
  displayName: 'Authentik Corporate Single Sign-On',
  authorizationEndpoint: '/api/auth/sign-in/social',
  appSignInEndpoint: '/api/auth/app-sign-in/start',
  appTokenEndpoint: '/api/auth/app-sign-in/token',
);

const _configuredAddress = 'https://bge.example.com';
const _mismatchNote =
    'Sign-in providers only work when this server is reached at '
    '$_configuredAddress.';

const _genericCopy =
    'Something went wrong signing in with the provider. Try again.';

Widget _wrap(Widget child, AuthBloc bloc, {double textScale = 1}) => MediaQuery(
  // Above MaterialApp on purpose: `MediaQuery.fromView` is inserted by
  // `View`, higher still, so this one wins for the subtree below.
  data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
  child: MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: AuthLocalizations.localizationsDelegates,
    supportedLocales: AuthLocalizations.supportedLocales,
    home: BlocProvider<AuthBloc>.value(value: bloc, child: child),
  ),
);

AuthScreen _screen(ServerIdentity identity) =>
    AuthScreen(identity: identity, serverDisplayName: 'Test BGE Server');

/// The provider button for [providerId].
Finder _button(String providerId) => find.byWidgetPredicate(
  (widget) =>
      widget is OidcStrategyButton && widget.strategy.providerId == providerId,
);

/// The Material button inside [_button], which holds the focus node.
Finder _material(String providerId) => find.descendant(
  of: _button(providerId),
  matching: find.byType(OutlinedButton),
);

OutlinedButton _materialOf(WidgetTester tester, String providerId) =>
    tester.widget<OutlinedButton>(_material(providerId));

/// The focus node [providerId]'s button takes focus through: the nearest one
/// above its label, whoever made it.
FocusNode _focusOf(WidgetTester tester, String providerId) => Focus.of(
  tester.element(
    find.descendant(of: _material(providerId), matching: find.byType(Text)),
  ),
);

Finder get _banner => find.byKey(AuthScreen.providerFailureBannerKey);

/// Provider sign-in on the auth screen (#583): the provider banner, the
/// buttons while a sign-in is open, and the states where a device or a
/// server can't offer it.
void main() {
  setUpAll(() {
    registerFallbackValue(const AuthFailureCleared());
    registerFallbackValue(kOidcStrategy);
  });

  late MockAuthBloc bloc;
  late StreamController<AuthBlocState> states;

  setUp(() {
    bloc = MockAuthBloc();
    stubProviderSignInAvailability(bloc);
  });

  /// Pumps the screen over [initial], with later states fed through
  /// [states].
  Future<void> pumpScreen(
    WidgetTester tester, {
    ServerIdentity? identity,
    AuthBlocState initial = const AuthUnauthenticated(),
    double textScale = 1,
  }) async {
    // Made here, where the screen listens to it: closing a stream nobody
    // listened to never completes, and the teardown would wait forever.
    states = StreamController<AuthBlocState>();
    addTearDown(states.close);
    whenListen(bloc, states.stream, initialState: initial);
    await tester.pumpWidget(
      _wrap(
        _screen(identity ?? testServerIdentity(hasOidc: true)),
        bloc,
        textScale: textScale,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Lands [state] and draws the frame it causes. The stream delivers it in a
  /// microtask, which a bare `pump()` flushes only after deciding there is no
  /// frame to draw; `pump(Duration.zero)` flushes first. Not pumpAndSettle,
  /// for states with a busy button: its spinner never settles.
  Future<void> land(WidgetTester tester, AuthBlocState state) async {
    states.add(state);
    await tester.pump(Duration.zero);
  }

  testWidgets('tapping a provider dispatches '
      'AuthProviderSignInRequested(strategy); no SnackBar appears', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Continue with Authentik'));
    await tester.pumpAndSettle();

    verify(() => bloc.add(const AuthProviderSignInRequested(kOidcStrategy)))
        .called(1);
    expect(find.byType(SnackBar), findsNothing);
  });

  group('the provider banner', () {
    testWidgets('a provider failure shows its banner above the provider '
        'buttons, titled "Couldn\'t sign in"', (tester) async {
      await pumpScreen(tester);
      states.add(
        const AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
      );
      await tester.pumpAndSettle();

      expect(_banner, findsOneWidget);
      expect(
        find.descendant(of: _banner, matching: find.text("Couldn't sign in")),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _banner, matching: find.text(_genericCopy)),
        findsOneWidget,
      );
      // Directly above the buttons, one step away, and below the email form:
      // in the provider section, not at the head of the page.
      expect(
        tester.getTopLeft(_button('authentik')).dy -
            tester.getBottomLeft(_banner).dy,
        BgeTokens.standard.spaceMd,
      );
      expect(
        tester.getTopLeft(_banner).dy,
        greaterThan(tester.getBottomLeft(find.byType(LoginForm)).dy),
      );
      // The email form never shows a provider failure.
      expect(find.byKey(AuthScreen.failureBannerKey), findsNothing);
    });

    // One expectation per reason, so a reason added to the enum without
    // copy fails here as well as in the screen's exhaustive switch.
    const copies = {
      ProviderSignInFailureReason.registrationDisabled:
          "This server isn't accepting new accounts. If you already have an "
          'account here, you can still sign in with it.',
      ProviderSignInFailureReason.emailUnverified:
          "Your sign-in provider hasn't confirmed your email address. Confirm "
          'it with the provider, then try again.',
      ProviderSignInFailureReason.accountNotLinked:
          'An account with this email already exists here. Sign in with its '
          'password instead.',
      ProviderSignInFailureReason.accessDenied:
          "The sign-in provider didn't allow this sign-in. If you think it "
          "should have, ask this server's administrator.",
      ProviderSignInFailureReason.providerUnavailable:
          "This sign-in provider isn't available right now. Try again later.",
      ProviderSignInFailureReason.startAgain:
          "The sign-in didn't finish, or took too long. Start it again.",
      ProviderSignInFailureReason.rateLimited:
          'Too many attempts. Wait a moment, then try again.',
      ProviderSignInFailureReason.network:
          'Could not reach the server. Check your connection.',
      ProviderSignInFailureReason.generic: _genericCopy,
    };

    test('every reason has an expected copy', () {
      expect(copies.keys, unorderedEquals(ProviderSignInFailureReason.values));
    });

    for (final MapEntry(key: reason, value: copy) in copies.entries) {
      testWidgets('each reason shows its copy: ${reason.name}', (tester) async {
        await pumpScreen(tester);
        states.add(AuthFailureProviderSignIn(reason));
        await tester.pumpAndSettle();

        expect(
          find.descendant(of: _banner, matching: find.text(copy)),
          findsOneWidget,
        );
      });
    }

    testWidgets('each reason shows its copy: rateLimited with a wait', (
      tester,
    ) async {
      await pumpScreen(tester);
      states.add(
        const AuthFailureProviderSignIn(
          ProviderSignInFailureReason.rateLimited,
          retryAfter: Duration(seconds: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: _banner,
          matching: find.text('Too many attempts. Try again in 7 seconds.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('each reason shows its copy: rateLimited with a zero wait '
        'reads as no wait', (tester) async {
      await pumpScreen(tester);
      states.add(
        const AuthFailureProviderSignIn(
          ProviderSignInFailureReason.rateLimited,
          retryAfter: Duration.zero,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: _banner,
          matching: find.text(
            'Too many attempts. Wait a moment, then try again.',
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('0 seconds'), findsNothing);
    });

    testWidgets('an OIDC-only server shows the provider banner (no email form '
        'exists)', (tester) async {
      await pumpScreen(
        tester,
        identity: testServerIdentity(hasEmailPassword: false, hasOidc: true),
      );
      states.add(
        const AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoginForm), findsNothing);
      expect(
        find.descendant(of: _banner, matching: find.text(_genericCopy)),
        findsOneWidget,
      );
    });

    testWidgets('an email-form failure stays on the form, not over the '
        'providers', (tester) async {
      await pumpScreen(tester);
      states.add(const AuthFailureInvalidCredentials());
      await tester.pumpAndSettle();

      expect(find.byKey(AuthScreen.failureBannerKey), findsOneWidget);
      expect(_banner, findsNothing);
    });

    testWidgets('the provider banner is announced (liveRegion) and is one '
        'semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester);
      states.add(
        const AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
      );
      await tester.pumpAndSettle();

      // Through the text, as the banner's own suite does: the merge boundary
      // sits below the banner's root.
      final title = tester.getSemantics(find.text("Couldn't sign in"));
      final message = tester.getSemantics(find.text(_genericCopy));
      expect(title.id, message.id, reason: 'title and message are one node');
      expect(
        message,
        isSemantics(
          label: "Couldn't sign in\n$_genericCopy",
          isLiveRegion: true,
          isFocusable: false,
        ),
      );
      handle.dispose();
    });
  });

  group('while a sign-in is open', () {
    testWidgets('while the browser is open the pressed button reads "Waiting '
        'for Authentik…", keeps focus, and ignores presses', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(
        tester,
        identity: testServerIdentity(
          oidcStrategies: const [kOidcStrategy, _keycloak],
        ),
      );
      final focus = _focusOf(tester, 'authentik');
      focus.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focus), reason: 'sanity');

      // The press itself is pinned above; here the sign-in it started opens.
      await land(tester, const AuthLoading(providerId: 'authentik'));

      // A disabled button drops focus (#607). This one keeps it, so a
      // screen-reader user back from the browser lands on the button they
      // pressed; so do the others, enabled in Material's terms.
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(_materialOf(tester, 'authentik').enabled, isTrue);
      expect(_materialOf(tester, 'keycloak').enabled, isTrue);
      expect(find.text('Waiting for Authentik\u{2026}'), findsOneWidget);
      expect(find.text('Continue with Keycloak'), findsOneWidget);
      expect(
        tester.getSemantics(_material('authentik')),
        isSemantics(
          label: 'Waiting for Authentik\u{2026}',
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      // The other provider is inert with it, not disabled: still focusable,
      // and its label kept.
      expect(
        tester.getSemantics(_material('keycloak')),
        isSemantics(
          label: 'Continue with Keycloak',
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );

      await tester.tap(_material('authentik'));
      await tester.tap(_material('keycloak'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      verifyNever(() => bloc.add(any()));
      expect(FocusManager.instance.primaryFocus, same(focus));

      // Back from the browser with a refusal: the banner lands above, and
      // focus is still where the user left it.
      states.add(
        const AuthFailureProviderSignIn(ProviderSignInFailureReason.startAgain),
      );
      await tester.pumpAndSettle();
      expect(_banner, findsOneWidget);
      expect(find.text('Continue with Authentik'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(focus));
      handle.dispose();
    });

    testWidgets('a cancelled sign-in returns the buttons to rest, with focus '
        'still on the pressed one', (tester) async {
      await pumpScreen(tester);
      final focus = _focusOf(tester, 'authentik');
      focus.requestFocus();
      await tester.pump();

      await land(tester, const AuthLoading(providerId: 'authentik'));
      expect(FocusManager.instance.primaryFocus, same(focus));
      states.add(const AuthUnauthenticated());
      await tester.pumpAndSettle();

      expect(find.text('Continue with Authentik'), findsOneWidget);
      expect(_banner, findsNothing);
      expect(FocusManager.instance.primaryFocus, same(focus));

      await tester.tap(_material('authentik'));
      verify(() => bloc.add(const AuthProviderSignInRequested(kOidcStrategy)))
          .called(1);
    });

    // An email sign-in and a sign-out are both `AuthLoading` with no
    // provider. The provider buttons are unavailable for a press that isn't
    // theirs, so they have no focus to keep, and are disabled as they were
    // before #583 (STYLE_GUIDE §5).
    testWidgets('while an email sign-in or a sign-out is in flight the '
        'provider buttons are disabled, with their labels', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(
        tester,
        identity: testServerIdentity(
          oidcStrategies: const [kOidcStrategy, _keycloak],
        ),
      );
      await land(tester, const AuthLoading());

      for (final (providerId, label) in const [
        ('authentik', 'Continue with Authentik'),
        ('keycloak', 'Continue with Keycloak'),
      ]) {
        expect(find.text(label), findsOneWidget);
        expect(_materialOf(tester, providerId).onPressed, isNull);
        expect(
          tester.getSemantics(_material(providerId)),
          isSemantics(
            label: label,
            isButton: true,
            isFocusable: false,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
      }

      await tester.ensureVisible(_material('authentik'));
      await tester.tap(_material('authentik'), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => bloc.add(any()));

      // Back at rest, they are live again.
      await land(tester, const AuthUnauthenticated());
      expect(_materialOf(tester, 'authentik').onPressed, isNotNull);
      handle.dispose();
    });

    testWidgets('while the browser is open the email form shows no busy copy, '
        'announces nothing, and its submit is disabled', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester);
      // At rest, the header's title is the screen's one live region.
      final liveRegions = find.semantics.byPredicate(
        (node) => node.flagsCollection.isLiveRegion,
      );
      expect(liveRegions, findsOneWidget, reason: 'sanity');
      await land(tester, const AuthLoading(providerId: 'authentik'));

      final form = find.byType(LoginForm);
      final submit = find.descendant(
        of: form,
        matching: find.widgetWithText(FilledButton, 'Sign In'),
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(
        find.descendant(
          of: form,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(find.text('Signing in, please wait'), findsNothing);
      expect(find.semantics.byLabel('Signing in, please wait'), findsNothing);
      // The attempt adds none: a busy submit would.
      expect(liveRegions, findsOneWidget);
      for (final field in tester.widgetList<TextField>(
        find.descendant(of: form, matching: find.byType(TextField)),
      )) {
        expect(field.readOnly, isFalse);
      }

      await tester.ensureVisible(submit);
      await tester.tap(submit, warnIfMissed: false);
      await tester.pump();
      verifyNever(() => bloc.add(any()));
      handle.dispose();
    });

    for (final standing in const <AuthBlocState>[
      AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
      AuthFailureInvalidCredentials(),
    ]) {
      testWidgets('a provider tap clears a standing failure before '
          'requesting: ${standing.runtimeType}', (tester) async {
        await pumpScreen(tester, initial: standing);

        await tester.ensureVisible(_material('authentik'));
        await tester.tap(_material('authentik'));
        await tester.pump();

        verifyInOrder([
          () => bloc.add(const AuthFailureCleared()),
          () => bloc.add(const AuthProviderSignInRequested(kOidcStrategy)),
        ]);
      });
    }
  });

  group('where provider sign-in is unavailable', () {
    testWidgets('an unsupported device shows every button disabled with the '
        '"not available on this device yet" label', (tester) async {
      stubProviderSignInAvailability(
        bloc,
        const ProviderSignInUnsupportedDevice(),
      );
      await pumpScreen(
        tester,
        identity: testServerIdentity(
          oidcStrategies: const [kOidcStrategy, _keycloak],
        ),
      );

      expect(
        find.text('Continue with Authentik (not available on this device yet)'),
        findsOneWidget,
      );
      expect(
        find.text('Continue with Keycloak (not available on this device yet)'),
        findsOneWidget,
      );
      expect(_materialOf(tester, 'authentik').enabled, isFalse);
      expect(_materialOf(tester, 'keycloak').enabled, isFalse);
      expect(find.textContaining('Sign-in providers only work'), findsNothing);

      await tester.ensureVisible(_material('authentik'));
      await tester.tap(_material('authentik'), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => bloc.add(any()));
    });

    testWidgets('an address mismatch disables the buttons and names the '
        'configured address once', (tester) async {
      final handle = tester.ensureSemantics();
      stubProviderSignInAvailability(
        bloc,
        const ProviderSignInAddressMismatch(_configuredAddress),
      );
      await pumpScreen(
        tester,
        identity: testServerIdentity(
          oidcStrategies: const [kOidcStrategy, _keycloak],
        ),
      );

      expect(find.text('Continue with Authentik'), findsOneWidget);
      expect(find.text('Continue with Keycloak'), findsOneWidget);
      expect(_materialOf(tester, 'authentik').enabled, isFalse);
      expect(_materialOf(tester, 'keycloak').enabled, isFalse);

      // One note for the group, under the last button, in its own node.
      expect(find.text(_mismatchNote), findsOneWidget);
      expect(find.textContaining(_configuredAddress), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_mismatchNote)).dy,
        greaterThan(tester.getBottomLeft(_button('keycloak')).dy),
      );
      expect(
        tester.getSemantics(find.text(_mismatchNote)),
        isSemantics(label: _mismatchNote),
      );

      await tester.ensureVisible(_material('authentik'));
      await tester.tap(_material('authentik'), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => bloc.add(any()));
      handle.dispose();
    });

    testWidgets('where provider sign-in is available there is no note', (
      tester,
    ) async {
      await pumpScreen(tester);

      expect(find.textContaining('Sign-in providers only work'), findsNothing);
      expect(_materialOf(tester, 'authentik').enabled, isTrue);
    });

    // The gate rebuilds the screen with a new identity, keeping its state:
    // the buttons follow the identity, so their availability must too.
    testWidgets('a new identity is read afresh: a mismatch the server has '
        'fixed enables the buttons and drops the note', (tester) async {
      stubProviderSignInAvailability(
        bloc,
        const ProviderSignInAddressMismatch(_configuredAddress),
      );
      await pumpScreen(tester);
      expect(find.text(_mismatchNote), findsOneWidget);
      expect(_materialOf(tester, 'authentik').enabled, isFalse);

      stubProviderSignInAvailability(bloc);
      await tester.pumpWidget(
        _wrap(
          _screen(
            testServerIdentity(
              oidcStrategies: const [kOidcStrategy, _keycloak],
            ),
          ),
          bloc,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(_mismatchNote), findsNothing);
      expect(_materialOf(tester, 'authentik').enabled, isTrue);
      expect(_materialOf(tester, 'keycloak').enabled, isTrue);
    });
  });

  group('at 320×480 and 2.0 text', () {
    /// Pumps the email and provider screen with [_longName] at 320×480 and
    /// 2.0, scrolls to the provider buttons as the user would, lands
    /// [failure], and checks that nothing overflowed and that the banner is
    /// wholly on screen.
    Future<void> expectLaysOut(
      WidgetTester tester, {
      required ProviderSignInAvailability availability,
      List<AuthBlocState> before = const [],
    }) async {
      useViewSize(tester, const Size(320, 480));
      stubProviderSignInAvailability(bloc, availability);
      await pumpScreen(
        tester,
        identity: testServerIdentity(oidcStrategies: const [_longName]),
        textScale: 2,
      );
      expect(
        pageScrollOf(tester).position.maxScrollExtent,
        greaterThan(0),
        reason:
            'sanity: the page must scroll at this size, or the reveal '
            'is not under test',
      );
      await tester.ensureVisible(_button('corp-sso'));
      await tester.pumpAndSettle();
      for (final state in before) {
        await land(tester, state);
        expect(tester.takeException(), isNull);
      }

      states.add(
        const AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // On screen, leading with its top edge, one spacing step or less below
      // the viewport's start (STYLE_GUIDE §4). Not the whole rect: under the
      // test font's one-em glyphs the titled banner is 522dp tall here, more
      // than the 480dp viewport, and #228 decided against a height cap.
      expect(
        topInViewport(tester, _banner),
        inInclusiveRange(0, BgeTokens.standard.spaceMd),
      );
    }

    testWidgets('at 320×480 and 2.0 text: long display name, unavailable '
        'label and banner lay out without overflow, and the banner is on '
        'screen', (tester) async {
      await expectLaysOut(
        tester,
        availability: const ProviderSignInUnsupportedDevice(),
      );
      expect(
        find.text(
          'Continue with Authentik Corporate Single Sign-On (not available '
          'on this device yet)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('at 320×480 and 2.0 text: long display name, mismatch note '
        'and banner lay out without overflow, and the banner is on screen', (
      tester,
    ) async {
      await expectLaysOut(
        tester,
        availability: const ProviderSignInAddressMismatch(_configuredAddress),
      );
      expect(find.text(_mismatchNote), findsOneWidget);
    });

    testWidgets('at 320×480 and 2.0 text: the long busy label lays out '
        'without overflow, and the banner after it is on screen', (
      tester,
    ) async {
      await expectLaysOut(
        tester,
        availability: const ProviderSignInAvailable(),
        before: const [AuthLoading(providerId: 'corp-sso')],
      );
    });
  });

  group('against a real bloc', () {
    late MockAuthRepository repo;
    late Completer<ProviderSignInOutcome> attempt;

    setUp(() {
      repo = MockAuthRepository();
      when(repo.watchAuthState).thenAnswer((_) => const Stream.empty());
      when(() => repo.providerSignInAvailability)
          .thenReturn(const ProviderSignInAvailable());
    });

    /// Pumps the screen over a real bloc. Each attempt waits on [attempt]
    /// unless [failFast], when it fails with a network refusal at once.
    Future<void> pumpReal(
      WidgetTester tester, {
      bool failFast = false,
      double textScale = 1,
    }) async {
      when(() => repo.signInWithProvider(any())).thenAnswer((_) {
        if (failFast) {
          return Future.error(
            const AuthProviderSignInException(
              ProviderSignInFailureReason.network,
            ),
          );
        }
        attempt = Completer<ProviderSignInOutcome>();
        return attempt.future;
      });
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: MaterialApp(
            theme: BgeTheme.light(),
            localizationsDelegates: AuthLocalizations.localizationsDelegates,
            supportedLocales: AuthLocalizations.supportedLocales,
            // `create`, as the router provides it: the provider closes the
            // bloc when the tree goes.
            home: BlocProvider<AuthBloc>(
              create: (_) => AuthBloc(authRepository: repo),
              child: _screen(testServerIdentity(hasOidc: true)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Presses the provider and lets the attempt fail with [reason].
    Future<void> failAttempt(
      WidgetTester tester,
      ProviderSignInFailureReason reason,
    ) async {
      await tester.ensureVisible(_material('authentik'));
      await tester.tap(_material('authentik'));
      await tester.pump();
      attempt.completeError(AuthProviderSignInException(reason));
      await tester.pumpAndSettle();
    }

    testWidgets('a mode switch retires the provider banner', (tester) async {
      await pumpReal(tester);
      await failAttempt(tester, ProviderSignInFailureReason.generic);
      expect(_banner, findsOneWidget);

      final toggle = find.text("Don't have an account? Register");
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.byType(RegisterForm), findsOneWidget, reason: 'sanity');
      expect(_banner, findsNothing);
    });

    testWidgets('the next attempt retires the banner while it runs, and a '
        'repeat of the failure brings it back', (tester) async {
      await pumpReal(tester);
      await failAttempt(tester, ProviderSignInFailureReason.startAgain);
      expect(_banner, findsOneWidget);

      await tester.ensureVisible(_material('authentik'));
      await tester.tap(_material('authentik'));
      await tester.pump();
      expect(_banner, findsNothing);
      expect(find.text('Waiting for Authentik\u{2026}'), findsOneWidget);

      attempt.completeError(
        const AuthProviderSignInException(
          ProviderSignInFailureReason.startAgain,
        ),
      );
      await tester.pumpAndSettle();
      expect(_banner, findsOneWidget);
    });

    // Web offline, or a platform channel that fails at once: the attempt
    // fails within the frame that started it, so "Waiting for…" never paints
    // and the clear never reaches the screen. Without a new banner the press
    // would look and sound like it did nothing.
    testWidgets('a repeat of a failure that lands before the next frame is a '
        'fresh banner, revealed and announced, with focus kept on the '
        'pressed button', (tester) async {
      const copy = 'Could not reach the server. Check your connection.';
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(320, 480));
      await pumpReal(tester, failFast: true, textScale: 2);
      await tester.ensureVisible(_material('authentik'));
      final focus = _focusOf(tester, 'authentik');
      focus.requestFocus();
      await tester.pump();

      // No frame between a press and its failure.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final first = tester.state(_banner);
      final firstNode = tester.getSemantics(find.text(copy)).id;

      // The user scrolls on, taking the banner's top out of view.
      final page = pageScrollOf(tester).position;
      page.jumpTo(page.maxScrollExtent);
      await tester.pump();
      expect(topInViewport(tester, _banner), lessThan(0), reason: 'sanity');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      verify(() => repo.signInWithProvider(kOidcStrategy)).called(2);
      expect(
        tester.state(_banner),
        isNot(same(first)),
        reason: 'a fresh banner, not the first one kept',
      );
      expect(
        tester.getSemantics(find.text(copy)).id,
        isNot(firstNode),
        reason: 'a new live-region node, so it is announced again',
      );
      expect(
        topInViewport(tester, _banner),
        inInclusiveRange(0, BgeTokens.standard.spaceMd),
        reason: 'revealed again',
      );
      expect(FocusManager.instance.primaryFocus, same(focus));
      handle.dispose();
    });
  });
}
