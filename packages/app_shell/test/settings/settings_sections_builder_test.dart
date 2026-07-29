import 'package:app_shell/app_shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements Storage {}

class _FakePerServerEntry implements SettingsEntry {
  const _FakePerServerEntry();
  @override
  String get id => 'fake_per_server';
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  group('buildSettingsSections', () {
    late ThemeModeCubit themeModeCubit;
    late LocaleCubit localeCubit;

    setUp(() {
      final storage = _MockStorage();
      when(() => storage.read(any())).thenReturn(null);
      when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
      when(() => storage.delete(any())).thenAnswer((_) async {});
      HydratedBloc.storage = storage;
      themeModeCubit = ThemeModeCubit();
      localeCubit = LocaleCubit();
    });

    tearDown(() {
      themeModeCubit.close();
      localeCubit.close();
    });

    List<SettingsSection> build({required List<Locale> supportedLocales}) =>
        buildSettingsSections(
          themeModeCubit: themeModeCubit,
          localeCubit: localeCubit,
          supportedLocales: supportedLocales,
        );

    SettingsSection appLevelOf(List<SettingsSection> sections) =>
        sections.firstWhere((s) => s.scope == SettingsScope.appLevel);

    test('the app-level section always carries the theme-mode entry', () {
      final sections = build(supportedLocales: const [Locale('en')]);
      expect(
        appLevelOf(sections).entries.map((e) => e.id),
        contains('theme_mode'),
      );
    });

    test('the language entry is omitted with a single supported locale', () {
      final sections = build(supportedLocales: const [Locale('en')]);
      expect(
        appLevelOf(sections).entries.map((e) => e.id),
        isNot(contains('language')),
      );
    });

    test('the language entry appears with more than one supported locale', () {
      final sections = build(
        supportedLocales: const [Locale('en'), Locale('es')],
      );
      expect(
        appLevelOf(sections).entries.map((e) => e.id),
        contains('language'),
      );
    });

    test('a per-server section is always present and empty at launch (for '
        'the screen to omit)', () {
      final sections = build(supportedLocales: const [Locale('en')]);
      final perServer = sections.firstWhere(
        (s) => s.scope == SettingsScope.perServer,
      );
      expect(perServer.entries, isEmpty);
    });

    test(
      'per-server entries, when supplied, populate the per-server section',
      () {
        final sections = buildSettingsSections(
          themeModeCubit: themeModeCubit,
          localeCubit: localeCubit,
          supportedLocales: const [Locale('en')],
          perServerEntries: const [_FakePerServerEntry()],
        );
        final perServer = sections.firstWhere(
          (s) => s.scope == SettingsScope.perServer,
        );
        expect(perServer.entries.map((e) => e.id), contains('fake_per_server'));
      },
    );
  });
}
