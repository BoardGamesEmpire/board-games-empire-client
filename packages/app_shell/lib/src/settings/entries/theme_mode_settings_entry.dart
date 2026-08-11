import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/shell_localizations.dart';
import '../settings_entry.dart';
import '../theme_mode_cubit.dart';

/// The theme-mode settings entry (#120): a labelled radio group of
/// system / light / dark, backed by [ThemeModeCubit].
///
/// Uses [RadioGroup] + [RadioListTile] (Flutter 3.32+) so each option
/// carries proper radio semantics and value announcement — not a bare
/// gesture — and inherits the theme's 48dp minimum tap target.
class ThemeModeSettingsEntry implements SettingsEntry {
  const ThemeModeSettingsEntry({required this.cubit});

  final ThemeModeCubit cubit;

  @override
  String get id => 'theme_mode';

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeModeCubit, ThemeMode>(
      bloc: cubit,
      builder: (context, mode) {
        final i18n = ShellLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                BgeTokens.of(context).spaceMd,
                BgeTokens.of(context).spaceSm,
                BgeTokens.of(context).spaceMd,
                0,
              ),
              child: Text(
                i18n.settingsThemeModeLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            RadioGroup<ThemeMode>(
              groupValue: mode,
              onChanged: (value) {
                if (value != null) cubit.select(value);
              },
              child: Column(
                children: [
                  RadioListTile<ThemeMode>(
                    key: const Key('settings_theme_system'),
                    value: ThemeMode.system,
                    title: Text(i18n.settingsThemeModeSystem),
                  ),
                  RadioListTile<ThemeMode>(
                    key: const Key('settings_theme_light'),
                    value: ThemeMode.light,
                    title: Text(i18n.settingsThemeModeLight),
                  ),
                  RadioListTile<ThemeMode>(
                    key: const Key('settings_theme_dark'),
                    value: ThemeMode.dark,
                    title: Text(i18n.settingsThemeModeDark),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
