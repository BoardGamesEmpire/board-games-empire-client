import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/l10n/auth_localizations_en.dart';
import 'package:auth/src/widgets/oidc_strategy_button.dart';

const _strategy = OidcStrategy(
  providerId: 'google-oidc',
  discoveryUrl: 'https://accounts.google.com/.well-known/openid-configuration',
  authorizationEndpoint: '/api/auth/sign-in/oauth2',
);

const _label = 'Continue with Google Oidc';

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

Widget _wrap({
  bool enabled = true,
  VoidCallback? onPressed,
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
        enabled: enabled,
        onPressed: onPressed ?? () {},
      ),
    ),
  ),
);

/// Pins the provider button's label, its one semantics node and its tap
/// target (#188). The provider's own display name replaces the title-cased id
/// once the sign-in flow reads it (#583).
void main() {
  testWidgets('the label comes from authContinueWith', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.text(_label), findsOneWidget);

    await tester.pumpWidget(_wrap(reworded: true));
    expect(find.text('Sign in through Google Oidc'), findsOneWidget);
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

    await tester.pumpWidget(_wrap(enabled: false));
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

    await tester.pumpWidget(_wrap(enabled: false, onPressed: () => taps++));
    await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
    expect(taps, 1);
  });
}
