import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/shell_localizations.dart';
import '../locale_cubit.dart';
import '../settings_entry.dart';

/// The language settings entry (#120 Q5): a labelled radio group of
/// "System default" plus one option per supported locale, backed by
/// [LocaleCubit] (`null` state = follow system).
///
/// The shell only composes this entry when more than one locale is
/// supported (see `buildSettingsSections`); at launch the app is
/// English-only, so it is dormant. When a second locale lands (#127) it
/// appears with no further wiring.
///
/// [localeLabelBuilder] supplies the display label for a locale; when
/// absent the BCP 47 tag is shown. Proper endonym labelling is #127.
class LanguageSettingsEntry implements SettingsEntry {
  const LanguageSettingsEntry({
    required this.cubit,
    required this.supportedLocales,
    this.localeLabelBuilder,
  });

  final LocaleCubit cubit;
  final List<Locale> supportedLocales;
  final String Function(BuildContext context, Locale locale)?
  localeLabelBuilder;

  @override
  String get id => 'language';

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LocaleCubit, Locale?>(
      bloc: cubit,
      builder: (context, selected) {
        final i18n = ShellLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                i18n.settingsLanguageLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            RadioGroup<Locale?>(
              groupValue: selected,
              onChanged: cubit.select,
              child: Column(
                children: [
                  RadioListTile<Locale?>(
                    key: const Key('settings_language_system'),
                    value: null,
                    title: Text(i18n.settingsLanguageSystemDefault),
                  ),
                  for (final locale in supportedLocales)
                    RadioListTile<Locale?>(
                      key: Key('settings_language_${locale.toLanguageTag()}'),
                      value: locale,
                      title: Text(
                        localeLabelBuilder?.call(context, locale) ??
                            locale.toLanguageTag(),
                      ),
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
