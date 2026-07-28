import 'package:flutter/widgets.dart';

import '../../l10n/shell_localizations.dart';
import 'entries/language_settings_entry.dart';
import 'entries/theme_mode_settings_entry.dart';
import 'locale_cubit.dart';
import 'settings_entry.dart';
import 'settings_section.dart';
import 'settings_scope.dart';
import 'theme_mode_cubit.dart';

/// Composes the settings sections the shell renders (#120).
///
/// Explicit, app_shell-local composition (Q1): the app-level section
/// always carries the theme-mode entry, plus the language entry **only
/// when more than one locale is supported** (Q5 visibility gate). A
/// per-server section is always returned for structural completeness but
/// is empty until a feature contributes a per-server entry
/// ([perServerEntries]); `SettingsScreen` omits it when empty or when no
/// server is active.
List<SettingsSection> buildSettingsSections({
  required ThemeModeCubit themeModeCubit,
  required LocaleCubit localeCubit,
  required List<Locale> supportedLocales,
  String Function(BuildContext context, Locale locale)? localeLabelBuilder,
  List<SettingsEntry> perServerEntries = const [],
}) {
  final appLevelEntries = <SettingsEntry>[
    ThemeModeSettingsEntry(cubit: themeModeCubit),
    if (supportedLocales.length > 1)
      LanguageSettingsEntry(
        cubit: localeCubit,
        supportedLocales: supportedLocales,
        localeLabelBuilder: localeLabelBuilder,
      ),
  ];

  return [
    SettingsSection(
      scope: SettingsScope.appLevel,
      titleBuilder: (context) =>
          ShellLocalizations.of(context).settingsSectionGeneral,
      entries: appLevelEntries,
    ),
    SettingsSection(scope: SettingsScope.perServer, entries: perServerEntries),
  ];
}
