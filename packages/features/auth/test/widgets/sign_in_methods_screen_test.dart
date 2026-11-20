import 'dart:async';

import 'package:auth/auth.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_bloc.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_state.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/auth_test_fixtures.dart';

const _returnPath = '/settings/sign-in-methods';
const _offlineReason = 'Needs a connection to the server';

OidcStrategy _strategy(String id, String name) => OidcStrategy(
  providerId: id,
  displayName: name,
  discoveryUrl: 'https://example.test/$id/.well-known/openid-configuration',
  authorizationEndpoint: '/auth/$id',
  appSignInEndpoint: '/app/$id',
  appTokenEndpoint: '/token/$id',
);

final OidcStrategy _authentik = _strategy('authentik', 'Authentik');
final OidcStrategy _google = _strategy('google', 'Google');

/// The live server sends `createdAt` on the password row too.
final _password = SignInMethod(
  id: 'pw',
  providerId: SignInMethod.passwordProviderId,
  linkedAt: DateTime(2026, 8, 2, 10),
);
final _authentikRow = SignInMethod(
  id: 'row-a',
  providerId: 'authentik',
  linkedAt: DateTime(2026, 11, 3, 12),
);
final _googleRow = SignInMethod(
  id: 'row-g',
  providerId: 'google',
  linkedAt: DateTime(2026, 10, 1, 9),
);

/// A provider discovery no longer lists.
final _retiredRow = SignInMethod(
  id: 'row-x',
  providerId: 'retired',
  linkedAt: DateTime(2026, 9, 14, 9),
);

const _yourMethods = 'Your sign-in methods';
const _linkSection = 'Link a sign-in provider';
const _removedName = 'A sign-in provider this server no longer offers';
const _lastWayIn = "Can't unlink: you have no other way to sign in";
const _notOffered = 'This server no longer accepts sign-in with a password';
const _loadFailed = "Couldn't load your sign-in methods.";
const _linkFailedTitle = "Couldn't link the sign-in provider";
const _unlinkFailedTitle = "Couldn't unlink";
const _generic = 'Something went wrong. Try again.';

Widget _app(Widget home, {ThemeData? theme, bool offline = false}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: AuthLocalizations.localizationsDelegates,
      supportedLocales: AuthLocalizations.supportedLocales,
      // Above the navigator, as the shell's host is, so a dialog reads it too.
      builder: (context, child) => BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: _offlineReason,
        child: child!,
      ),
      home: home,
    );

Finder _row(String id) => find.byKey(SignInMethodsScreen.rowKey(id));
Finder _unlink(String id) => find.byKey(SignInMethodsScreen.unlinkKey(id));
Finder _link(String providerId) =>
    find.byKey(SignInMethodsScreen.linkKey(providerId));
Finder get _outcome => find.byKey(SignInMethodsScreen.outcomeKey);

/// Whether the Material button [finder] finds would answer a press.
bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

/// Whether the page's title holds keyboard focus.
bool _titleHasFocus(WidgetTester tester) {
  final title = find.ancestor(
    of: find.text('Sign-in methods'),
    matching: find.byType(Focus),
  );
  return tester.widget<Focus>(title.first).focusNode?.hasPrimaryFocus ?? false;
}

/// The one semantics node a screen reader meets for [label].
SemanticsNode _nodeLabelled(String label) {
  final found = find.semantics.byLabel(label);
  expect(found, findsOne, reason: 'one node named "$label"');
  return found.evaluate().single;
}

void main() {
  late MockAuthRepository repo;

  setUpAll(() => registerFallbackValue(_authentik));

  setUp(() {
    repo = MockAuthRepository();
    when(() => repo.providerLinkSupported).thenReturn(true);
    when(() => repo.takeProviderLinkReturn()).thenReturn(null);
    when(
      () => repo.listSignInMethods(),
    ).thenAnswer((_) async => [_password, _authentikRow]);
    when(
      () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
    ).thenAnswer((_) async {});
    when(() => repo.unlinkSignInMethod(any())).thenAnswer((_) async {});
  });

  SignInMethodsScreen screen({
    List<OidcStrategy>? strategies,
    bool passwordSignInOffered = true,
  }) => SignInMethodsScreen(
    repository: repo,
    strategies: strategies ?? [_authentik, _google],
    passwordSignInOffered: passwordSignInOffered,
    returnPath: _returnPath,
  );

  void stubMethods(List<SignInMethod> methods) =>
      when(() => repo.listSignInMethods()).thenAnswer((_) async => methods);

  void stubReturn(ProviderLinkReturn r) =>
      when(() => repo.takeProviderLinkReturn()).thenReturn(r);

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<SignInMethod>? methods,
    List<OidcStrategy>? strategies,
    bool passwordSignInOffered = true,
    bool offline = false,
    ThemeData? theme,
  }) async {
    if (methods != null) stubMethods(methods);
    await tester.pumpWidget(
      _app(
        screen(
          strategies: strategies,
          passwordSignInOffered: passwordSignInOffered,
        ),
        offline: offline,
        theme: theme,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Presses [id]'s Unlink, and settles on the confirm it opens.
  Future<void> openConfirm(WidgetTester tester, String id) async {
    await tester.ensureVisible(_unlink(id));
    await tester.tap(_unlink(id));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  group('SignInMethodsScreen', () {
    group('the list', () {
      testWidgets('lists each method under its name, with when it was '
          'linked, and offers Link for each provider not yet linked', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow, _retiredRow],
        );

        expect(find.text('Sign-in methods'), findsOneWidget);
        expect(find.text(_yourMethods), findsOneWidget);
        expect(
          find.descendant(of: _row('pw'), matching: find.text('Password')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _row('row-a'), matching: find.text('Authentik')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _row('row-a'),
            matching: find.text('Linked Nov 3, 2026'),
          ),
          findsOneWidget,
        );
        // A removed provider is never named by its id.
        expect(
          find.descendant(of: _row('row-x'), matching: find.text(_removedName)),
          findsOneWidget,
        );
        expect(find.textContaining('retired'), findsNothing);
        // The password row shows no date, though the server sends one, and
        // has no Unlink.
        expect(
          find.descendant(
            of: _row('pw'),
            matching: find.textContaining('Linked'),
          ),
          findsNothing,
        );
        expect(_unlink('pw'), findsNothing);
        expect(_unlink('row-a'), findsOneWidget);
        expect(_unlink('row-x'), findsOneWidget);

        expect(find.text(_linkSection), findsOneWidget);
        expect(_link('google'), findsOneWidget);
        expect(find.text('Link Google'), findsOneWidget);
        expect(_link('authentik'), findsNothing);
      });

      testWidgets('the headings are headings', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpScreen(tester, methods: [_password]);

        expect(
          tester.getSemantics(find.text(_yourMethods)),
          isSemantics(isHeader: true),
        );
        expect(
          tester.getSemantics(find.text(_linkSection)),
          isSemantics(isHeader: true),
        );
        handle.dispose();
      });

      testWidgets('with every provider linked, there is no Link section', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow, _googleRow],
        );

        expect(find.text(_linkSection), findsNothing);
        expect(find.textContaining('Link '), findsNothing);
      });

      testWidgets('the withheld Unlink is disabled, and its name says why', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        // No password, so Authentik is the only way in.
        await pumpScreen(tester, methods: [_authentikRow]);

        expect(_enabled(tester, _unlink('row-a')), isFalse);
        expect(find.text(_lastWayIn), findsOneWidget);
        expect(
          _nodeLabelled(_lastWayIn),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );

        await tester.tap(_unlink('row-a'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verifyNever(() => repo.unlinkSignInMethod(any()));
        handle.dispose();
      });

      testWidgets('a password the server no longer offers counts for '
          'nothing: the last provider\u{2019}s Unlink is withheld', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow],
          passwordSignInOffered: false,
        );

        expect(find.text('Password'), findsOneWidget);
        expect(_enabled(tester, _unlink('row-a')), isFalse);
        expect(find.text(_lastWayIn), findsOneWidget);
      });

      testWidgets('a password the server no longer offers says so, read with '
          'its name', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow],
          passwordSignInOffered: false,
        );

        expect(
          find.descendant(of: _row('pw'), matching: find.text(_notOffered)),
          findsOneWidget,
        );
        expect(
          find.semantics.byLabel(RegExp('^Password\n$_notOffered\$')),
          findsOne,
        );
        handle.dispose();
      });

      testWidgets('a password the server offers carries no note', (
        tester,
      ) async {
        await pumpScreen(tester, methods: [_password, _authentikRow]);

        expect(find.text(_notOffered), findsNothing);
      });

      testWidgets('a removed provider alone is withheld too, for the same '
          'reason', (tester) async {
        // A removed provider is no way in, so with nothing else it is the
        // last row, and the reason must be true for it as well (#582).
        await pumpScreen(tester, methods: [_retiredRow]);

        expect(_enabled(tester, _unlink('row-x')), isFalse);
        expect(
          find.descendant(of: _row('row-x'), matching: find.text(_lastWayIn)),
          findsOneWidget,
        );
      });

      testWidgets('each Unlink shows Unlink, and is named for its method', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow, _retiredRow],
        );

        // The name holds the visible text (WCAG 2.5.3), and says which row.
        expect(
          find.descendant(of: _unlink('row-a'), matching: find.text('Unlink')),
          findsOneWidget,
        );
        expect(
          _nodeLabelled('Unlink Authentik'),
          isSemantics(
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        // A removed provider is never named by its id, and its name reads as
        // one phrase, as its confirm's title does, not as the row's name
        // dropped in after "Unlink".
        expect(
          find.descendant(of: _unlink('row-x'), matching: find.text('Unlink')),
          findsOneWidget,
        );
        expect(
          _nodeLabelled(
            'Unlink the sign-in provider this server no longer offers',
          ),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
        );
        expect(find.semantics.byLabel('Unlink $_removedName'), findsNothing);
        // No button is named by its visible text alone.
        expect(find.semantics.byLabel('Unlink'), findsNothing);
        handle.dispose();
      });

      testWidgets('where linking is not supported, Link is disabled, and its '
          'label says why', (tester) async {
        final handle = tester.ensureSemantics();
        when(() => repo.providerLinkSupported).thenReturn(false);
        await pumpScreen(tester, methods: [_password]);

        const unavailable =
            "Linking Google isn't available in this app yet. Link it from "
            'the web app.';
        expect(_enabled(tester, _link('google')), isFalse);
        expect(find.text(unavailable), findsOneWidget);
        expect(find.text('Link Google'), findsNothing);
        expect(
          _nodeLabelled(unavailable),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );

        // A rounded box, not the theme's stadium, which at 320dp and 2.0 text
        // would clip a reason this long to a circle (#764).
        expect(
          tester
              .widget<ButtonStyleButton>(_link('google'))
              .style
              ?.shape
              ?.resolve(const {WidgetState.disabled}),
          isA<RoundedRectangleBorder>(),
        );

        await tester.tap(_link('google'), warnIfMissed: false);
        await tester.pump();
        verifyNever(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        );
        handle.dispose();
      });
    });

    group('link', () {
      testWidgets('Link starts linking that provider, back to this screen', (
        tester,
      ) async {
        await pumpScreen(tester);

        await tester.tap(_link('google'));
        await tester.pumpAndSettle();

        verify(
          () => repo.linkProvider(_google, returnPath: _returnPath),
        ).called(1);
      });

      testWidgets('while a link is out, its Link is inert and says so, and '
          'the other Link is disabled', (tester) async {
        final handle = tester.ensureSemantics();
        final out = Completer<void>();
        when(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).thenAnswer((_) => out.future);
        await pumpScreen(tester, methods: [_password]);
        final authentikAtRest = tester.getSemantics(_link('authentik'));

        await tester.tap(_link('authentik'));
        await tester.pump();

        // The pressed one keeps its node and its focus, and does nothing.
        final pressed = tester.getSemantics(_link('authentik'));
        expect(pressed.id, authentikAtRest.id);
        expect(find.text('Linking Authentik…'), findsOneWidget);
        expect(_enabled(tester, _link('authentik')), isTrue);
        expect(
          pressed,
          isSemantics(
            label: 'Linking Authentik…',
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
        // The other is disabled: no press of its own made it so.
        expect(_enabled(tester, _link('google')), isFalse);
        expect(
          tester.getSemantics(_link('google')),
          isSemantics(
            label: 'Link Google',
            isButton: true,
            isFocusable: false,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );

        await tester.tap(_link('authentik'));
        await tester.tap(_link('google'), warnIfMissed: false);
        await tester.pump();
        verify(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).called(1);

        // The page stayed: the user stopped the link.
        out.complete();
        await tester.pumpAndSettle();
        expect(find.text('Link Authentik'), findsOneWidget);
        expect(_enabled(tester, _link('authentik')), isTrue);
        expect(_enabled(tester, _link('google')), isTrue);
        handle.dispose();
      });
    });

    group('one write at a time', () {
      testWidgets('while a link is starting, every Unlink is disabled', (
        tester,
      ) async {
        final out = Completer<void>();
        when(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).thenAnswer((_) => out.future);
        await pumpScreen(tester, methods: [_password, _authentikRow]);
        expect(_enabled(tester, _unlink('row-a')), isTrue);

        await tester.tap(_link('google'));
        await tester.pump();

        expect(_enabled(tester, _unlink('row-a')), isFalse);
        await tester.tap(_unlink('row-a'), warnIfMissed: false);
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);

        out.complete();
        await tester.pumpAndSettle();
        expect(_enabled(tester, _unlink('row-a')), isTrue);
      });

      testWidgets('while an unlink is out, every Link is disabled', (
        tester,
      ) async {
        final out = Completer<void>();
        when(
          () => repo.unlinkSignInMethod(any()),
        ).thenAnswer((_) => out.future);
        await pumpScreen(tester, methods: [_password, _authentikRow]);
        expect(_enabled(tester, _link('google')), isTrue);

        await openConfirm(tester, 'row-a');
        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(_enabled(tester, _link('google')), isFalse);
        await tester.tap(_link('google'), warnIfMissed: false);
        await tester.pump();
        verifyNever(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        );

        out.complete();
        stubMethods([_password]);
        await tester.pumpAndSettle();
        expect(_enabled(tester, _link('google')), isTrue);
      });
    });

    group('unlink', () {
      testWidgets('Unlink asks first, naming the method; confirming unlinks '
          'that row', (tester) async {
        await pumpScreen(tester);

        await openConfirm(tester, 'row-a');
        expect(find.text('Unlink Authentik?'), findsOneWidget);
        expect(
          find.text(
            "You won't be able to sign in with Authentik until you link it "
            'again, which needs a recent sign-in.',
          ),
          findsOneWidget,
        );
        verifyNever(() => repo.unlinkSignInMethod(any()));

        stubMethods([_password]);
        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pumpAndSettle();

        verify(() => repo.unlinkSignInMethod('row-a')).called(1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(_row('row-a'), findsNothing);
      });

      testWidgets('a long provider name scrolls in the confirm at 320dp and '
          '2.0 text, and confirming still unlinks', (tester) async {
        tester.view
          ..physicalSize = const Size(320, 480)
          ..devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        // Discovery puts no limit on a provider's display name.
        final longName = _strategy(
          'authentik',
          'Authentik Single Sign-On for the Riverside Board Game Society',
        );
        await pumpScreen(tester, strategies: [longName, _google]);

        await openConfirm(tester, 'row-a');
        expect(tester.takeException(), isNull);
        // Scrolled to its end, the body's last line is in view.
        final scroller = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(scroller).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.textContaining('until you link it again')).bottom,
          lessThanOrEqualTo(tester.getRect(scroller).bottom),
        );

        stubMethods([_password]);
        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pumpAndSettle();
        verify(() => repo.unlinkSignInMethod('row-a')).called(1);
      });

      testWidgets('Cancel unlinks nothing', (tester) async {
        await pumpScreen(tester);

        await openConfirm(tester, 'row-a');
        await tester.tap(find.byKey(SignInMethodsScreen.cancelUnlinkKey));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        verifyNever(() => repo.unlinkSignInMethod(any()));
        expect(_row('row-a'), findsOneWidget);
      });

      testWidgets('a removed provider\u{2019}s confirm says it can\u{2019}t be '
          'linked again, and never names its id', (tester) async {
        await pumpScreen(tester, methods: [_password, _retiredRow]);

        await openConfirm(tester, 'row-x');
        expect(
          find.text(
            'Unlink the sign-in provider this server no longer offers?',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            "This server no longer offers it, so it can't be linked again.",
          ),
          findsOneWidget,
        );
        // Not the provider rows' copy, which promises a link again.
        expect(find.text('Unlink $_removedName?'), findsNothing);
        expect(find.textContaining('until you link it again'), findsNothing);
        expect(find.textContaining('retired'), findsNothing);
      });

      testWidgets('opening the confirm retires the outcome banner, so none '
          'sits under the dialog', (tester) async {
        stubReturn(const ProviderLinkSucceeded('authentik'));
        await pumpScreen(tester);
        expect(_outcome, findsOneWidget);

        await openConfirm(tester, 'row-a');

        expect(_outcome, findsNothing);
        expect(find.text('Authentik is linked'), findsNothing);
      });

      testWidgets('while an unlink is out, its Unlink is inert and says so, '
          'and the other rows\u{2019} Unlink is disabled', (tester) async {
        final handle = tester.ensureSemantics();
        final out = Completer<void>();
        when(
          () => repo.unlinkSignInMethod(any()),
        ).thenAnswer((_) => out.future);
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow, _googleRow],
        );
        final atRest = tester.getSemantics(_unlink('row-a'));

        await openConfirm(tester, 'row-a');
        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final pressed = tester.getSemantics(_unlink('row-a'));
        expect(pressed.id, atRest.id);
        expect(_enabled(tester, _unlink('row-a')), isTrue);
        expect(
          pressed,
          isSemantics(
            label: 'Unlinking…',
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
        expect(_enabled(tester, _unlink('row-g')), isFalse);
        expect(
          tester.getSemantics(_unlink('row-g')),
          isSemantics(
            label: 'Unlink Google',
            isButton: true,
            isFocusable: false,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );

        // Neither opens a confirm meanwhile.
        await tester.tap(_unlink('row-a'));
        await tester.tap(_unlink('row-g'), warnIfMissed: false);
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);

        out.complete();
        stubMethods([_password, _googleRow]);
        await tester.pumpAndSettle();
        expect(_enabled(tester, _unlink('row-g')), isTrue);
        handle.dispose();
      });
    });

    group('outcomes', () {
      /// The live region a screen reader hears for [message].
      void expectAnnounced(WidgetTester tester, String message) {
        expect(find.text(message), findsOneWidget);
        expect(
          find.descendant(of: _outcome, matching: find.text(message)),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.text(message)),
          isSemantics(isLiveRegion: true),
        );
      }

      testWidgets('a link that came back says the provider is linked', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        stubReturn(const ProviderLinkSucceeded('authentik'));
        await pumpScreen(tester);

        expectAnnounced(tester, 'Authentik is linked');
        handle.dispose();
      });

      testWidgets('a link that came back for a provider discovery no longer '
          'lists names none', (tester) async {
        final handle = tester.ensureSemantics();
        stubReturn(const ProviderLinkSucceeded('retired'));
        await pumpScreen(tester);

        expectAnnounced(tester, 'The sign-in provider is linked');
        handle.dispose();
      });

      testWidgets('a refused link that came back is titled, and says why', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        stubReturn(
          const ProviderLinkFailed(
            'authentik',
            AuthProviderLinkException(
              ProviderLinkFailureReason.alreadyLinkedElsewhere,
            ),
          ),
        );
        await pumpScreen(tester);

        expect(
          find.descendant(of: _outcome, matching: find.text(_linkFailedTitle)),
          findsOneWidget,
        );
        expectAnnounced(
          tester,
          'That Authentik identity is already linked to another user here.',
        );
        handle.dispose();
      });

      testWidgets('an identity linked elsewhere, for a provider discovery no '
          'longer lists, names none', (tester) async {
        final handle = tester.ensureSemantics();
        stubReturn(
          const ProviderLinkFailed(
            'retired',
            AuthProviderLinkException(
              ProviderLinkFailureReason.alreadyLinkedElsewhere,
            ),
          ),
        );
        await pumpScreen(tester);

        expectAnnounced(
          tester,
          'That identity is already linked to another user here.',
        );
        handle.dispose();
      });

      testWidgets('an unlink says what was unlinked', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpScreen(tester);
        await openConfirm(tester, 'row-a');
        stubMethods([_password]);
        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pumpAndSettle();

        expectAnnounced(tester, 'Authentik is unlinked');
        handle.dispose();
      });

      testWidgets('an unlinked removed provider is named without its id', (
        tester,
      ) async {
        await pumpScreen(tester, methods: [_password, _retiredRow]);
        await openConfirm(tester, 'row-x');
        stubMethods([_password]);
        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pumpAndSettle();

        expect(find.text('$_removedName is unlinked'), findsOneWidget);
      });

      // Link failures, by what the repository threw.
      final linkFailures = <String, (Exception, String)>{
        'needs a recent sign-in': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.needsRecentSignIn,
          ),
          'Linking needs a recent sign-in. Sign out, sign in again, then '
              'link it.',
        ),
        'linked to another user': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.alreadyLinkedElsewhere,
          ),
          'That Google identity is already linked to another user here.',
        ),
        'email unconfirmed': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.emailUnconfirmed,
          ),
          "The provider hasn't confirmed the email address, so it can't be "
              'linked. Confirm it with the provider, then try again.',
        ),
        'access denied': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.accessDenied,
          ),
          "The sign-in provider didn't allow this sign-in. If you think it "
              "should have, ask this server's administrator.",
        ),
        'provider unavailable': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.providerUnavailable,
          ),
          "This sign-in provider isn't available right now. Try again later.",
        ),
        'start again': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.startAgain,
          ),
          "The sign-in didn't finish, or took too long. Start it again.",
        ),
        'rate limited, with a wait': (
          const AuthRateLimitedException(retryAfter: Duration(seconds: 30)),
          'Too many attempts. Try again in 30 seconds.',
        ),
        'rate limited, with no usable wait': (
          const AuthRateLimitedException(
            retryAfter: Duration(milliseconds: 400),
          ),
          'Too many attempts. Wait a moment, then try again.',
        ),
        'network': (
          const AuthNetworkException(message: 'offline'),
          'Could not reach the server. Check your connection.',
        ),
        'generic': (
          const AuthProviderLinkException(ProviderLinkFailureReason.generic),
          _generic,
        ),
      };

      for (final MapEntry(key: name, value: (error, copy))
          in linkFailures.entries) {
        testWidgets('a failed link ($name) is titled, and says why', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          when(
            () =>
                repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
          ).thenThrow(error);
          await pumpScreen(tester);

          await tester.tap(_link('google'));
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: _outcome,
              matching: find.text(_linkFailedTitle),
            ),
            findsOneWidget,
          );
          expectAnnounced(tester, copy);
          handle.dispose();
        });
      }

      // Unlink failures, by what the repository threw.
      final unlinkFailures = <String, (Exception, String)>{
        'needs a recent sign-in': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.needsRecentSignIn,
          ),
          'Unlinking needs a recent sign-in. Sign out, sign in again, then '
              'unlink it.',
        ),
        'last way in': (
          const AuthProviderLinkException(
            ProviderLinkFailureReason.lastSignInMethod,
          ),
          "It's your only way to sign in, so it can't be unlinked.",
        ),
        'network': (
          const AuthNetworkException(message: 'offline'),
          'Could not reach the server. Check your connection.',
        ),
        'generic': (
          const AuthProviderLinkException(ProviderLinkFailureReason.generic),
          _generic,
        ),
      };

      for (final MapEntry(key: name, value: (error, copy))
          in unlinkFailures.entries) {
        testWidgets('a failed unlink ($name) is titled, and says why', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          when(() => repo.unlinkSignInMethod(any())).thenThrow(error);
          await pumpScreen(tester);

          await openConfirm(tester, 'row-a');
          await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: _outcome,
              matching: find.text(_unlinkFailedTitle),
            ),
            findsOneWidget,
          );
          expectAnnounced(tester, copy);
          expect(_row('row-a'), findsOneWidget);
          handle.dispose();
        });
      }

      testWidgets('Dismiss retires the banner', (tester) async {
        stubReturn(const ProviderLinkSucceeded('authentik'));
        await pumpScreen(tester);

        await tester.tap(find.byKey(SignInMethodsScreen.dismissKey));
        await tester.pumpAndSettle();

        expect(_outcome, findsNothing);
      });

      testWidgets('Dismiss from the keyboard hands focus to the title', (
        tester,
      ) async {
        stubReturn(const ProviderLinkSucceeded('authentik'));
        await pumpScreen(tester);

        final dismiss = Focus.of(tester.element(find.text('Dismiss')))
          ..requestFocus();
        await tester.pump();
        expect(dismiss.hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(_outcome, findsNothing);
        expect(_titleHasFocus(tester), isTrue);
      });

      testWidgets('a link that came back shows over a failed first load, and '
          'stays the one banner once Try again loads the list', (tester) async {
        final handle = tester.ensureSemantics();
        stubReturn(const ProviderLinkSucceeded('authentik'));
        var calls = 0;
        when(() => repo.listSignInMethods()).thenAnswer((_) async {
          if (calls++ == 0) {
            throw const AuthNetworkException(message: 'offline');
          }
          return [_password, _authentikRow];
        });
        await pumpScreen(tester);

        expect(find.byType(BgeErrorState), findsOneWidget);
        expectAnnounced(tester, 'Authentik is linked');
        expect(
          tester.getRect(_outcome).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(BgeErrorState)).top),
        );
        final banner = tester.element(_outcome);
        final node = tester.getSemantics(find.text('Authentik is linked')).id;

        await tester.tap(find.byKey(SignInMethodsScreen.retryKey));
        await tester.pumpAndSettle();

        expect(calls, 2);
        expect(_row('row-a'), findsOneWidget);
        expectAnnounced(tester, 'Authentik is linked');
        // The same banner and the same live node throughout, so a screen
        // reader isn't told the result again when the list arrives.
        expect(tester.element(_outcome), same(banner));
        expect(
          tester.getSemantics(find.text('Authentik is linked')).id,
          node,
        );
        handle.dispose();
      });

      testWidgets('the same failure twice is a new banner, said again', (
        tester,
      ) async {
        when(
          () => repo.linkProvider(any(), returnPath: any(named: 'returnPath')),
        ).thenThrow(
          const AuthProviderLinkException(ProviderLinkFailureReason.generic),
        );
        await pumpScreen(tester);

        await tester.tap(_link('google'));
        await tester.pumpAndSettle();
        final first = tester.element(_outcome);

        await tester.tap(_link('google'));
        await tester.pumpAndSettle();
        expect(_outcome, findsOneWidget);
        expect(tester.element(_outcome), isNot(same(first)));
      });
    });

    group('offline', () {
      testWidgets('Link and Unlink are disabled, each says why, and one note '
          'says it once', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpScreen(tester, offline: true);

        expect(_enabled(tester, _unlink('row-a')), isFalse);
        expect(_enabled(tester, _link('google')), isFalse);
        expect(
          tester.getSemantics(_unlink('row-a')),
          isSemantics(hint: _offlineReason, isEnabled: false),
        );
        expect(
          tester.getSemantics(_link('google')),
          isSemantics(hint: _offlineReason, isEnabled: false),
        );
        expect(find.text(_offlineReason), findsOneWidget);
        handle.dispose();
      });

      testWidgets('online, there is no note', (tester) async {
        await pumpScreen(tester);

        expect(find.text(_offlineReason), findsNothing);
        expect(_enabled(tester, _unlink('row-a')), isTrue);
        expect(_enabled(tester, _link('google')), isTrue);
      });
    });

    group('loading', () {
      testWidgets('while loading, a spinner says what is loading', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final pending = Completer<List<SignInMethod>>();
        when(() => repo.listSignInMethods()).thenAnswer((_) => pending.future);
        await tester.pumpWidget(_app(screen()));
        await tester.pump();

        expect(find.byType(BgeLoadingState), findsOneWidget);
        expect(
          find.semantics.byLabel('Loading your sign-in methods…'),
          findsOne,
        );

        pending.complete([_password]);
        await tester.pumpAndSettle();
        expect(find.byType(BgeLoadingState), findsNothing);
        handle.dispose();
      });

      testWidgets('a failed load offers Try again, and Try again loads again, '
          'with focus on the title meanwhile', (tester) async {
        var calls = 0;
        when(() => repo.listSignInMethods()).thenAnswer((_) async {
          if (calls++ == 0) {
            throw const AuthNetworkException(message: 'offline');
          }
          return [_password];
        });
        await pumpScreen(tester);

        expect(find.byType(BgeErrorState), findsOneWidget);
        expect(find.text(_loadFailed), findsOneWidget);
        expect(find.text(_yourMethods), findsNothing);

        await tester.tap(find.byKey(SignInMethodsScreen.retryKey));
        await tester.pumpAndSettle();

        expect(calls, 2);
        expect(find.byType(BgeErrorState), findsNothing);
        expect(_row('pw'), findsOneWidget);
        final title = find.ancestor(
          of: find.text('Sign-in methods'),
          matching: find.byType(Focus),
        );
        expect(
          tester.widget<Focus>(title.first).focusNode?.hasPrimaryFocus,
          isTrue,
        );
      });
    });

    group('focus', () {
      testWidgets('an unlink that takes the focused row hands focus to the '
          'title', (tester) async {
        final out = Completer<void>();
        when(
          () => repo.unlinkSignInMethod(any()),
        ).thenAnswer((_) => out.future);
        await pumpScreen(
          tester,
          methods: [_password, _authentikRow, _googleRow],
        );

        final unlinkFocus =
            tester.widget<ButtonStyleButton>(_unlink('row-a')).focusNode!
              ..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);

        await tester.tap(find.byKey(SignInMethodsScreen.confirmUnlinkKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        // The pressed Unlink keeps focus while its unlink is out.
        expect(unlinkFocus.hasPrimaryFocus, isTrue);

        stubMethods([_password, _googleRow]);
        out.complete();
        await tester.pumpAndSettle();

        expect(_row('row-a'), findsNothing);
        final title = find.ancestor(
          of: find.text('Sign-in methods'),
          matching: find.byType(Focus),
        );
        expect(
          tester.widget<Focus>(title.first).focusNode?.hasPrimaryFocus,
          isTrue,
        );
      });
    });

    group('the bloc', () {
      /// The screen's own bloc, which its builder names.
      SignInMethodsBloc blocOf(WidgetTester tester) => tester
          .widget<BlocBuilder<SignInMethodsBloc, SignInMethodsState>>(
            find.byType(BlocBuilder<SignInMethodsBloc, SignInMethodsState>),
          )
          .bloc!;

      testWidgets('closes as the route pops, while it is still on its way '
          'out', (tester) async {
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => screen()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final bloc = blocOf(tester);
        expect(bloc.isClosed, isFalse);

        Navigator.of(tester.element(find.byType(SignInMethodsScreen))).pop();
        await tester.pump();

        expect(find.byType(SignInMethodsScreen), findsOneWidget);
        expect(bloc.isClosed, isTrue);

        await tester.pumpAndSettle();
        expect(find.byType(SignInMethodsScreen), findsNothing);
      });

      testWidgets('closes when the screen goes without a pop', (tester) async {
        await pumpScreen(tester);
        final bloc = blocOf(tester);
        expect(bloc.isClosed, isFalse);

        await tester.pumpWidget(_app(const SizedBox()));

        expect(bloc.isClosed, isTrue);
      });
    });

    group('accessibility audit', () {
      Future<void> Function(WidgetTester, ThemeData) loaded({
        List<SignInMethod>? methods,
        bool offline = false,
        bool passwordSignInOffered = true,
      }) => (tester, theme) async {
        if (methods != null) stubMethods(methods);
        await tester.pumpWidget(
          _app(
            screen(passwordSignInOffered: passwordSignInOffered),
            theme: theme,
            offline: offline,
          ),
        );
      };

      // The page runs past the fold at 320dp and 2.0 text, so each loaded
      // state is audited in a view tall enough to hold it whole.
      Future<void> wholePage(WidgetTester tester) async {
        await useWholePage(tester);
        expect(find.text(_yourMethods), findsOneWidget);
        expectWholePage(tester);
      }

      auditScreen(
        'loaded, whole page',
        pump: loaded(methods: [_password, _authentikRow]),
        arrange: wholePage,
      );

      auditScreen(
        'withheld, removed and not supported here, whole page',
        pump: (tester, theme) async {
          when(() => repo.providerLinkSupported).thenReturn(false);
          await loaded(methods: [_authentikRow, _retiredRow])(tester, theme);
        },
        arrange: wholePage,
        // The withheld Unlink and the Link this device can't start are
        // disabled and drawn dimmed by design; WCAG 1.4.3 exempts inactive
        // controls, and the enabled ones pass in 'loaded, whole page'.
        textContrast: false,
      );

      auditScreen(
        'a password the server no longer accepts, whole page',
        pump: loaded(
          methods: [_password, _authentikRow],
          passwordSignInOffered: false,
        ),
        arrange: (tester) async {
          await wholePage(tester);
          expect(find.text(_notOffered), findsOneWidget);
        },
        // The withheld Unlink is disabled and drawn dimmed by design; WCAG
        // 1.4.3 exempts inactive controls.
        textContrast: false,
      );

      auditScreen(
        'offline, whole page',
        pump: loaded(offline: true),
        arrange: (tester) async {
          await wholePage(tester);
          expect(find.text(_offlineReason), findsOneWidget);
        },
        // Every control is disabled offline; WCAG 1.4.3 exempts them.
        textContrast: false,
      );

      auditScreen(
        'an outcome, whole page',
        pump: (tester, theme) async {
          stubReturn(
            const ProviderLinkFailed(
              'authentik',
              AuthProviderLinkException(
                ProviderLinkFailureReason.alreadyLinkedElsewhere,
              ),
            ),
          );
          await loaded()(tester, theme);
        },
        arrange: (tester) async {
          await wholePage(tester);
          expect(_outcome, findsOneWidget);
        },
      );

      auditScreen(
        'an outcome over a failed load, whole page',
        pump: (tester, theme) async {
          stubReturn(const ProviderLinkSucceeded('authentik'));
          when(
            () => repo.listSignInMethods(),
          ).thenThrow(const AuthNetworkException(message: 'offline'));
          await tester.pumpWidget(_app(screen(), theme: theme));
        },
        arrange: (tester) async {
          await useWholePage(tester);
          expect(_outcome, findsOneWidget);
          expect(find.text(_loadFailed), findsOneWidget);
          expectWholePage(tester);
        },
      );

      auditScreen(
        'the unlink confirm',
        pump: loaded(),
        arrange: (tester) async {
          await tester.pumpAndSettle();
          await openConfirm(tester, 'row-a');
        },
      );

      auditScreen(
        'load failed',
        pump: (tester, theme) async {
          when(
            () => repo.listSignInMethods(),
          ).thenThrow(const AuthNetworkException(message: 'offline'));
          await tester.pumpWidget(_app(screen(), theme: theme));
        },
        arrange: (tester) async {
          await tester.pumpAndSettle();
          expect(find.text(_loadFailed), findsOneWidget);
        },
      );

      auditScreen(
        'loading',
        pump: (tester, theme) async {
          when(
            () => repo.listSignInMethods(),
          ).thenAnswer((_) => Completer<List<SignInMethod>>().future);
          await tester.pumpWidget(_app(screen(), theme: theme));
        },
        // The spinner never settles.
        settle: false,
      );
    });
  });
}
