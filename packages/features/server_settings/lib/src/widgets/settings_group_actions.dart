import 'package:flutter/material.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What a failed save of a settings group says (#807).
///
/// [SettingsSaveFailure.passwordRequired] reads as the server refusing the
/// values. Only a change of mail server asks for the password: the Mail
/// group puts that on its password field instead, and another group's patch
/// makes no such change, so were the server to ask, it refused the values.
String settingsSaveFailureMessage(
  ServerSettingsLocalizations l10n,
  SettingsSaveFailure failure,
) => switch (failure) {
  SettingsSaveFailure.nothingChanged => l10n.settingsNothingChanged,
  SettingsSaveFailure.refused => l10n.settingsRefused,
  SettingsSaveFailure.rejected ||
  SettingsSaveFailure.passwordRequired => l10n.settingsRejected,
  SettingsSaveFailure.failed => l10n.settingsFailed,
};

/// Whether a settings group's save may be sent now (#807).
///
/// Saving is a direct write (#49), so not offline; one group saves at a time;
/// and only a role that may change the settings saves. Save's enablement and
/// each form's submit follow this one rule, so a submit that doesn't come
/// through Save, such as Enter in a field, is held to it as well.
bool settingsGroupMaySave(
  BuildContext context, {
  required bool maySave,
  required bool saving,
  required bool otherGroupSaving,
}) =>
    maySave &&
    !saving &&
    !otherGroupSaving &&
    !BgeConnectivityScope.offlineOf(context);

/// The end of a settings group's form (#807): what its last save came to,
/// its Save, and under Save whatever else the group offers, such as the Mail
/// group's test email ([trailing]). Every group ends this way, so they read
/// and behave alike.
///
/// - **Saved.** [savedMessage] sits above Save while [saved].
/// - **Failed.** The failure sits on Save, through [BgeFormActions], titled
///   [failureTitle]: some of the messages state only a cause.
/// - **Offline.** Saving is a direct write (#49), so Save is disabled and
///   carries the reason as its hint. The reason is drawn once, under Save,
///   for Save and [trailing] alike.
/// - **The other group saving.** Save is disabled, and carries why as its
///   hint, with no line drawn: the other group's Save shows what is going
///   on. Offline, the offline reason is the hint instead.
/// - **No [maySave].** No Save and no [trailing]. [focusNode] goes around
///   them, so the form can hand on the focus they had as they go; it must
///   not take focus itself. A failure still shows: a refused save whose
///   access check then takes [maySave] away must not vanish unexplained,
///   while the form puts back the saved values.
class SettingsGroupActions extends StatelessWidget {
  const SettingsGroupActions({
    required this.maySave,
    required this.saving,
    required this.otherGroupSaving,
    required this.saved,
    required this.focusNode,
    required this.onSave,
    required this.saveKey,
    required this.saveLabel,
    required this.savingLabel,
    required this.savedKey,
    required this.savedMessage,
    required this.failureKey,
    required this.failureTitle,
    this.failure,
    this.trailing,
    super.key,
  });

  /// Whether the caller may change the settings.
  final bool maySave;

  /// Whether this group's save is in flight.
  final bool saving;

  /// Whether the other group's save is in flight.
  final bool otherGroupSaving;

  /// Whether this group's last save landed, until the group is edited.
  final bool saved;

  /// Around Save and [trailing].
  final FocusNode focusNode;

  /// The form's submit.
  final VoidCallback onSave;

  final Key saveKey;
  final String saveLabel;
  final String savingLabel;
  final Key savedKey;
  final String savedMessage;
  final Key failureKey;
  final String failureTitle;

  /// Why this group's last save didn't land, or null for nothing to show
  /// here.
  final SettingsSaveFailure? failure;

  /// Shown under Save while [maySave].
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final failure = this.failure;
    final trailing = this.trailing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (saved || maySave || failure != null) const BgeGap.lg(),
        if (saved) ...[
          BgeInlineBanner(
            key: savedKey,
            tone: BgeBannerTone.success,
            message: savedMessage,
          ),
          const BgeGap.md(),
        ],
        if (maySave)
          Focus(
            focusNode: focusNode,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                BgeFormActions(
                  failure: failure == null
                      ? null
                      : BgeFormFailure(
                          key: failureKey,
                          title: failureTitle,
                          message: settingsSaveFailureMessage(l10n, failure),
                        ),
                  action: BgeOnlineOnly(
                    // One note for the group, drawn below: Save and
                    // [trailing] alike.
                    showNote: false,
                    // Merged into Save's node by the wrapper above it. The
                    // hint says what is drawn: offline that is the note
                    // alone, so the wrapper's offline reason is the only
                    // hint. The Send test email button's reasons are both
                    // drawn, so it carries both.
                    child: Semantics(
                      hint: otherGroupSaving && !offline
                          ? l10n.settingsOtherGroupSaving
                          : null,
                      child: BgeSubmitButton(
                        key: saveKey,
                        label: saveLabel,
                        progressLabel: savingLabel,
                        submitting: saving,
                        onPressed:
                            settingsGroupMaySave(
                              context,
                              maySave: maySave,
                              saving: saving,
                              otherGroupSaving: otherGroupSaving,
                            )
                            ? onSave
                            : null,
                      ),
                    ),
                  ),
                ),
                // Only offline: online it would still take its gap.
                if (offline) ...[
                  const BgeGap.sm(),
                  const BgeOnlineOnlyNote(),
                ],
                if (trailing != null) ...[const BgeGap.lg(), trailing],
              ],
            ),
          )
        // As BgeFormActions draws it, without the Save it sits on.
        else if (failure != null)
          BgeInlineBanner(
            key: failureKey,
            tone: BgeBannerTone.error,
            title: failureTitle,
            message: settingsSaveFailureMessage(l10n, failure),
          ),
      ],
    );
  }
}
