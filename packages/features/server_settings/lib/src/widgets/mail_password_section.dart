import 'package:flutter/material.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/mail/mail_controls.dart';
import 'package:server_settings/src/mail/mail_patch.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The focus nodes of the Mail form's password section (#807).
///
/// The form owns them, so it can hand focus to the button that replaces the
/// one pressed, and hand on the focus the buttons hold as they go.
final class MailPasswordFocus {
  /// Around the buttons, which go when the role may no longer save; the
  /// handle on their focus. It can't take focus itself.
  final FocusNode actions = FocusNode(
    debugLabel: 'mail password actions',
    canRequestFocus: false,
  );

  final FocusNode change = FocusNode(debugLabel: 'Change password');
  final FocusNode remove = FocusNode(debugLabel: 'Remove password');
  final FocusNode keep = FocusNode(debugLabel: 'Keep password');
  final FocusNode keepSaved = FocusNode(debugLabel: 'Keep saved password');

  void dispose() {
    for (final node in [actions, change, remove, keep, keepSaved]) {
      node.dispose();
    }
  }
}

/// The Mail form's password (#807): a field while a new one is entered, or
/// with none saved, with Keep saved password and Remove when one is saved;
/// otherwise a line saying one is saved, or will be removed, and the buttons
/// that change that.
///
/// Draws [edit] and reports a press through [onEdit]; the form moves the
/// state and the focus.
class MailPasswordSection extends StatelessWidget {
  const MailPasswordSection({
    required this.edit,
    required this.passwordSaved,
    required this.maySave,
    required this.readOnly,
    required this.buttonsEnabled,
    required this.focus,
    required this.onEdit,
    super.key,
  });

  static const Key fieldKey = Key('mail_settings_form.password');
  static const Key changeKey = Key('mail_settings_form.change');
  static const Key removeKey = Key('mail_settings_form.remove');
  static const Key keepKey = Key('mail_settings_form.keep');
  static const Key keepSavedKey = Key('mail_settings_form.keep_saved');

  final PasswordEdit edit;

  /// Whether the server holds a password.
  final bool passwordSaved;

  /// Whether the caller may change the settings: no buttons without it.
  final bool maySave;

  final bool readOnly;
  final bool buttonsEnabled;
  final MailPasswordFocus focus;
  final ValueChanged<PasswordEdit> onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    // Offered beside Change and beside Keep saved password, one at a time:
    // the field's error asks to enter the password again or remove it.
    final remove = _button(
      removeKey,
      focus.remove,
      PasswordEdit.remove,
      l10n.mailPasswordRemove,
    );

    if (edit == PasswordEdit.replace) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: fieldKey,
            formControlName: MailControls.password,
            label: l10n.mailPasswordLabel,
            isPassword: true,
            revealLabel: l10n.mailPasswordShow,
            obscureLabel: l10n.mailPasswordHide,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              MailErrors.passwordRequired: (_) => l10n.mailPasswordRequired,
              MailErrors.emptyPassword: (_) => l10n.mailPasswordEmpty,
              MailErrors.tooLong: (_) => mailTooLongMessage(l10n),
            },
          ),
          if (passwordSaved && maySave)
            _buttons(context, [
              _button(
                keepSavedKey,
                focus.keepSaved,
                PasswordEdit.keep,
                l10n.mailPasswordKeepSaved,
              ),
              remove,
            ]),
        ],
      );
    }

    final theme = Theme.of(context);
    final removing = edit == PasswordEdit.remove;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.mailPasswordLabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const BgeGap.xs(),
        // A live region: Remove and Keep change only this line, and the
        // button that takes focus doesn't say it.
        Semantics(
          container: true,
          liveRegion: true,
          child: Text(
            removing ? l10n.mailPasswordRemoving : l10n.mailPasswordSaved,
          ),
        ),
        if (maySave)
          _buttons(
            context,
            removing
                ? [
                    _button(
                      keepKey,
                      focus.keep,
                      PasswordEdit.keep,
                      l10n.mailPasswordKeep,
                    ),
                  ]
                : [
                    _button(
                      changeKey,
                      focus.change,
                      PasswordEdit.replace,
                      l10n.mailPasswordChange,
                    ),
                    remove,
                  ],
          ),
      ],
    );
  }

  Widget _buttons(BuildContext context, List<Widget> children) => Focus(
    focusNode: focus.actions,
    child: Wrap(spacing: BgeTokens.of(context).spaceSm, children: children),
  );

  Widget _button(
    Key key,
    FocusNode node,
    PasswordEdit to,
    String label,
  ) => TextButton(
    key: key,
    focusNode: node,
    onPressed: buttonsEnabled ? () => onEdit(to) : null,
    child: Text(label),
  );
}
