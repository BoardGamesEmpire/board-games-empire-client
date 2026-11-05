import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/l10n/auth_localizations_en.dart';
import 'package:auth/src/widgets/oidc_strategy_button.dart';

const _strategy = OidcStrategy(
  providerId: 'my-idp',
  displayName: 'Authentik',
  discoveryUrl: 'https://accounts.google.com/.well-known/openid-configuration',
  authorizationEndpoint: '/api/auth/sign-in/social',
  appSignInEndpoint: '/api/auth/app-sign-in/start',
  appTokenEndpoint: '/api/auth/app-sign-in/token',
);

const _label = 'Continue with Authentik';
const _busyLabel = 'Waiting for Authentik…';
const _unavailableLabel =
    'Continue with Authentik (not available on this device yet)';

/// The catalog with the button's label reworded. English is the only locale,
/// so this is what tells a label read from the catalog apart from one built
/// in code.
class _RewordedCatalog extends AuthLocalizationsEn {
  @override
  String authContinueWith(String provider) => 'Sign in through $provider';
}

class _RewordedDelegate extends LocalizationsDelegate<AuthLocalizations> {
  const _RewordedDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AuthLocalizations> load(Locale locale) =>
      SynchronousFuture(_RewordedCatalog());

  @override
  bool shouldReload(_RewordedDelegate old) => false;
}

/// [BgeTheme.light], with its tap-target token changed when [minTapTarget]
/// is given.
ThemeData _theme({double? minTapTarget}) {
  final base = BgeTheme.light();
  if (minTapTarget == null) return base;
  return base.copyWith(
    extensions: [
      for (final extension in base.extensions.values)
        if (extension is BgeTokens)
          extension.copyWith(minTapTarget: minTapTarget)
        else
          extension,
    ],
  );
}

/// Hosts the button. [disabled] passes a null `onPressed`; otherwise it is
/// [onPressed], or a no-op.
Widget _wrap({
  bool disabled = false,
  VoidCallback? onPressed,
  bool busy = false,
  bool inert = false,
  bool unavailableOnDevice = false,
  bool reworded = false,
  double? minTapTarget,
}) => MaterialApp(
  // A new tree whenever the catalog or the token changes, rather than asking
  // the existing one to reload.
  key: ValueKey((reworded, minTapTarget)),
  theme: _theme(minTapTarget: minTapTarget),
  localizationsDelegates: [
    if (reworded) const _RewordedDelegate(),
    for (final delegate in AuthLocalizations.localizationsDelegates)
      if (!reworded || delegate.type != AuthLocalizations) delegate,
  ],
  supportedLocales: AuthLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(
      child: OidcStrategyButton(
        strategy: _strategy,
        onPressed: disabled ? null : onPressed ?? () {},
        busy: busy,
        inert: inert,
        unavailableOnDevice: unavailableOnDevice,
      ),
    ),
  ),
);

FocusNode _focus(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byType(OutlinedButton)).focusNode!;

bool _enabled(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byType(OutlinedButton)).enabled;

/// Pins the provider button's label, its one semantics node and its tap
/// target (#188). The label carries the provider's own display name (#583).
///
/// While its own sign-in is open it is busy, and while another provider's
/// is, inert: either way it stays enabled and keeps focus, and a press does
/// nothing.
/// On a device without provider sign-in it is disabled, and its label says
/// why (#583).
void main() {
  testWidgets('the label reads the display name, not the id', (tester) async {
    await tester.pumpWidget(_wrap());

    expect(find.text('Continue with Authentik'), findsOneWidget);
    expect(find.text('Continue with My Idp'), findsNothing);
  });

  testWidgets('the label comes from authContinueWith', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.text(_label), findsOneWidget);

    await tester.pumpWidget(_wrap(reworded: true));
    expect(find.text('Sign in through Authentik'), findsOneWidget);
  });

  testWidgets('one semantics node, as a button with the label', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(_wrap());
    final nodes = find.semantics.byLabel(_label);
    // A wrapper restating what the button already reports splits it in two,
    // and a screen reader then announces the provider twice.
    expect(nodes, findsOne);
    expect(
      nodes.evaluate().single,
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
    );

    await tester.pumpWidget(_wrap(disabled: true));
    expect(find.semantics.byLabel(_label), findsOne);
    expect(
      find.semantics.byLabel(_label).evaluate().single,
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );

    handle.dispose();
  });

  testWidgets('the tap target is the token minimum', (tester) async {
    double height() => tester.getSize(find.byType(OutlinedButton)).height;

    await tester.pumpWidget(_wrap());
    expect(height(), greaterThanOrEqualTo(BgeTokens.standard.minTapTarget));

    // Taller than the standard 48, so a literal would fall short of it.
    await tester.pumpWidget(_wrap(minTapTarget: 64));
    expect(height(), greaterThanOrEqualTo(64));
  });

  testWidgets('tapping calls onPressed, and a disabled button does not', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_wrap(onPressed: () => taps++));
    await tester.tap(find.byType(OutlinedButton));
    expect(taps, 1);

    await tester.pumpWidget(_wrap(disabled: true, onPressed: () => taps++));
    await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
    expect(taps, 1);
  });
  group('busy and inert (#583)', () {
    testWidgets('busy reads "Waiting for Authentik…", keeps focus, and a '
        'press does nothing', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(onPressed: () => taps++));
      _focus(tester).requestFocus();
      await tester.pump();

      await tester.pumpWidget(_wrap(busy: true, onPressed: () => taps++));
      expect(find.text(_busyLabel), findsOneWidget);
      expect(find.text(_label), findsNothing);
      // Enabled in Material's terms, which is what lets it keep focus: a
      // disabled button drops it (#607).
      expect(_enabled(tester), isTrue);
      expect(_focus(tester).hasPrimaryFocus, isTrue);

      await tester.tap(find.byType(OutlinedButton));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('inert keeps its label and focus, and a press does nothing', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(onPressed: () => taps++));
      _focus(tester).requestFocus();
      await tester.pump();

      await tester.pumpWidget(_wrap(inert: true, onPressed: () => taps++));
      expect(find.text(_label), findsOneWidget);
      expect(_enabled(tester), isTrue);
      expect(_focus(tester).hasPrimaryFocus, isTrue);

      await tester.tap(find.byType(OutlinedButton));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 0);

      await tester.pumpWidget(_wrap(onPressed: () => taps++));
      await tester.tap(find.byType(OutlinedButton));
      expect(taps, 1);
    });

    testWidgets('one semantics node at rest, busy and inert, named by the '
        'visible label; busy or inert, it reads as not enabled with no tap', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap());
      final rest = tester.getSemantics(find.byType(OutlinedButton));
      expect(
        rest,
        isSemantics(
          label: _label,
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );

      await tester.pumpWidget(_wrap(busy: true));
      final busy = tester.getSemantics(find.byType(OutlinedButton));
      // The same node, so a screen reader's cursor stays put as it flips.
      expect(busy.id, rest.id);
      expect(find.semantics.byLabel(_busyLabel), findsOne);
      expect(
        busy,
        isSemantics(
          label: _busyLabel,
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );

      await tester.pumpWidget(_wrap(inert: true));
      final inert = tester.getSemantics(find.byType(OutlinedButton));
      expect(inert.id, rest.id);
      expect(
        inert,
        isSemantics(
          label: _label,
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      handle.dispose();
    });
  });

  group('unavailable (#583)', () {
    testWidgets('on an unsupported device it is disabled, with the reason in '
        'its label', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        _wrap(unavailableOnDevice: true, onPressed: () => taps++),
      );

      expect(find.text(_unavailableLabel), findsOneWidget);
      expect(find.text(_label), findsNothing);
      expect(_enabled(tester), isFalse);
      expect(find.semantics.byLabel(_unavailableLabel), findsOne);
      expect(
        find.semantics.byLabel(_unavailableLabel).evaluate().single,
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );

      await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
      expect(taps, 0);
      handle.dispose();
    });

    testWidgets('a null onPressed disables it with its normal label', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(disabled: true));

      expect(find.text(_label), findsOneWidget);
      expect(_enabled(tester), isFalse);
    });
  });
}
