import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A new API key's secret, shown the one time the server gives it (#1028).
///
/// From the top: the key's name, as a heading; the secret, as text the user
/// can select, in a monospace face so that an `l`, an `I` and a `1` tell
/// apart; Copy; a warning that this is the only time the key is shown; and
/// Done, which calls [onDone].
///
/// ## The secret goes nowhere else
///
/// It is drawn once, as its own text, and read to a screen reader as that
/// text's value. It is in no label, hint, tooltip or key, and in nothing
/// this widget says: the SnackBar after a copy says "Key copied", and a
/// copy that fails is not logged, since the platform's error is not this
/// widget's to vouch for. Copy puts it on the clipboard, which is the user's
/// own doing.
///
/// ## Copy
///
/// The clipboard is a round trip to the platform, so the button can look
/// idle and be pressed again: each press copies, and the newest answer
/// replaces the last one's SnackBar. The SnackBar is the whole confirmation,
/// since it is a live region already. A copy the platform refuses says so,
/// and that the text can be selected and copied by hand. Copy is never
/// disabled, so it keeps focus through its own press.
///
/// ## The warning
///
/// A warning banner, said as it arrives while [announce] is set. It does not
/// bring itself into view: the panel's top, with the key, is what a new
/// panel shows. The page clears [announce] once something over the page has
/// said the same, so the banner is not read again as that closes.
class SecretPanel extends StatefulWidget {
  const SecretPanel({
    required this.created,
    required this.onDone,
    this.announce = true,
    super.key,
  });

  /// On the secret's `SelectableText`.
  static const Key secretKey = Key('api_key_secret.secret');

  /// On Copy's button.
  static const Key copyKey = Key('api_key_secret.copy');

  /// On the warning's banner.
  static const Key noticeKey = Key('api_key_secret.notice');

  /// On Done's button.
  static const Key doneKey = Key('api_key_secret.done');

  /// The key the server made, with its secret.
  final CreatedApiKey created;

  /// Leaves the panel: the user has what they need of it.
  final VoidCallback onDone;

  /// Whether the warning is said as it appears.
  final bool announce;

  @override
  State<SecretPanel> createState() => _SecretPanelState();
}

class _SecretPanelState extends State<SecretPanel> {
  /// Counts copies, so an answer that a later press has overtaken says
  /// nothing.
  int _copyToken = 0;

  Future<void> _copy(ApiKeysLocalizations l10n) async {
    // Claimed before the await: presses are not serialised, and the platform
    // need not answer them in order.
    final token = ++_copyToken;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: widget.created.secret));
      copied = true;
    } on Object {
      // Not rethrown: the press discards this future, so an error escaping
      // it would raise the app's crash prompt over the one time the key is
      // shown. Not logged either: see "The secret goes nowhere else".
    }
    if (!mounted || token != _copyToken) return;
    // A new bar replaces the last, so presses don't stack confirmations.
    ScaffoldMessenger.of(context).replaceSnackBar(
      copied ? l10n.apiKeySecretCopied : l10n.apiKeySecretCopyFailed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final created = widget.created;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            created.apiKey.name ?? l10n.apiKeyUnnamed,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const BgeGap.lg(),
        Text(l10n.apiKeySecretLabel, style: theme.textTheme.labelLarge),
        const BgeGap.sm(),
        DecoratedBox(
          decoration: ShapeDecoration(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(tokens.radiusMd),
              side: BorderSide(color: BgeLineColors.of(context).rowOutline),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.all(tokens.spaceMd),
            // At least a tap target tall: the text is selected by a long
            // press, and a short key is a single line.
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tokens.minTapTarget),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SelectableText(
                  key: SecretPanel.secretKey,
                  created.secret,
                  // Monospace so that look-alike characters tell apart: the
                  // one override of the type scale, which still gives the
                  // size and the colour.
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontFamily: BgeTypography.monospaceFamily,
                  ),
                ),
              ),
            ),
          ),
        ),
        const BgeGap.md(),
        OutlinedButton.icon(
          key: SecretPanel.copyKey,
          onPressed: () => unawaited(_copy(l10n)),
          icon: const Icon(Icons.copy_outlined),
          // OutlinedButton.icon puts the label in a Flexible, so it wraps.
          label: Text(l10n.apiKeySecretCopy),
        ),
        const BgeGap.lg(),
        BgeInlineBanner(
          key: SecretPanel.noticeKey,
          tone: BgeBannerTone.warning,
          message: l10n.apiKeySecretOnce,
          announce: widget.announce,
          // The panel's top, with the key, is what shows first.
          reveal: false,
        ),
        const BgeGap.lg(),
        FilledButton(
          key: SecretPanel.doneKey,
          onPressed: widget.onDone,
          child: Text(l10n.apiKeySecretDone),
        ),
      ],
    );
  }
}
