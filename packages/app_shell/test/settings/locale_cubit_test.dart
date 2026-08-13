import 'dart:ui';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements Storage {}

void main() {
  group('LocaleCubit', () {
    late Storage storage;

    setUp(() {
      storage = _MockStorage();
      when(() => storage.read(any())).thenReturn(null);
      when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
      when(() => storage.delete(any())).thenAnswer((_) async {});
      HydratedBloc.storage = storage;
    });

    test('defaults to null (follow system) when nothing is stored', () {
      final cubit = LocaleCubit();
      addTearDown(cubit.close);
      expect(cubit.state, isNull);
    });

    blocTest<LocaleCubit, Locale?>(
      'select(locale) emits it and persists its language tag',
      build: LocaleCubit.new,
      act: (cubit) => cubit.select(const Locale('es')),
      expect: () => const [Locale('es')],
      verify: (_) {
        final captured = verify(
          () => storage.write('LocaleCubit', captureAny()),
        ).captured;
        expect(captured.last, {'languageTag': 'es'});
      },
    );

    blocTest<LocaleCubit, Locale?>(
      'select(null) after a value returns to follow-system and persists null',
      build: LocaleCubit.new,
      act: (cubit) => cubit
        ..select(const Locale('es'))
        ..select(null),
      expect: () => const [Locale('es'), null],
      verify: (_) {
        final captured = verify(
          () => storage.write('LocaleCubit', captureAny()),
        ).captured;
        expect(captured.last, {'languageTag': null});
      },
    );

    test('hydrates a plain language tag', () {
      when(() => storage.read('LocaleCubit')).thenReturn({'languageTag': 'en'});
      final cubit = LocaleCubit();
      addTearDown(cubit.close);
      expect(cubit.state, const Locale('en'));
    });

    test('hydrates a language+region tag', () {
      when(
        () => storage.read('LocaleCubit'),
      ).thenReturn({'languageTag': 'de-DE'});
      final cubit = LocaleCubit();
      addTearDown(cubit.close);
      expect(cubit.state, const Locale('de', 'DE'));
    });

    test('hydrates a language+script tag', () {
      when(
        () => storage.read('LocaleCubit'),
      ).thenReturn({'languageTag': 'zh-Hant'});
      final cubit = LocaleCubit();
      addTearDown(cubit.close);
      expect(cubit.state?.languageCode, 'zh');
      expect(cubit.state?.scriptCode, 'Hant');
      expect(cubit.state?.countryCode, isNull);
    });

    test('treats a null/empty stored tag as follow-system', () {
      when(() => storage.read('LocaleCubit')).thenReturn({'languageTag': null});
      final cubit = LocaleCubit();
      addTearDown(cubit.close);
      expect(cubit.state, isNull);
    });

    test('treats a corrupt stored tag as follow-system instead of throwing '
        'or minting an invalid locale', () {
      for (final corrupt in ['-US', '123', '@@', 'e', 'toolonglang']) {
        when(
          () => storage.read('LocaleCubit'),
        ).thenReturn({'languageTag': corrupt});
        final cubit = LocaleCubit();
        addTearDown(cubit.close);
        expect(
          cubit.state,
          isNull,
          reason: 'tag "$corrupt" should follow system',
        );
      }
    });
  });
}
