import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements Storage {}

void main() {
  group('ThemeModeCubit', () {
    late Storage storage;

    setUp(() {
      storage = _MockStorage();
      when(() => storage.read(any())).thenReturn(null);
      when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
      when(() => storage.delete(any())).thenAnswer((_) async {});
      HydratedBloc.storage = storage;
    });

    test('defaults to ThemeMode.system when nothing is stored', () {
      final cubit = ThemeModeCubit();
      addTearDown(cubit.close);
      expect(cubit.state, ThemeMode.system);
    });

    blocTest<ThemeModeCubit, ThemeMode>(
      'select(dark) emits dark and persists {themeMode: dark}',
      build: ThemeModeCubit.new,
      act: (cubit) => cubit.select(ThemeMode.dark),
      expect: () => const [ThemeMode.dark],
      verify: (_) {
        final captured = verify(
          () => storage.write('ThemeModeCubit', captureAny()),
        ).captured;
        expect(captured.last, {'themeMode': 'dark'});
      },
    );

    test('hydrates a stored value', () {
      when(
        () => storage.read('ThemeModeCubit'),
      ).thenReturn({'themeMode': 'light'});
      final cubit = ThemeModeCubit();
      addTearDown(cubit.close);
      expect(cubit.state, ThemeMode.light);
    });

    test('falls back to system on an unknown stored value (e.g. a removed '
        'mode from an older build)', () {
      when(
        () => storage.read('ThemeModeCubit'),
      ).thenReturn({'themeMode': 'highContrast'});
      final cubit = ThemeModeCubit();
      addTearDown(cubit.close);
      expect(cubit.state, ThemeMode.system);
    });

    test('falls back to system on a malformed payload', () {
      when(() => storage.read('ThemeModeCubit')).thenReturn({'themeMode': 42});
      final cubit = ThemeModeCubit();
      addTearDown(cubit.close);
      expect(cubit.state, ThemeMode.system);
    });
  });
}
