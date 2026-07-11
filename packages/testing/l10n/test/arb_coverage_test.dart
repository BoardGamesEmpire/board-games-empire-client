import 'dart:convert';
import 'dart:io';

import 'package:l10n_test_support/l10n_test_support.dart';
import 'package:test/test.dart';

/// Pins the ARB analysis contract for the repo i18n policy (#33):
/// template descriptions are mandatory, unknown keys are surfaced,
/// partial coverage is data (untranslated keys), not an error.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('arb_coverage_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  void writeArb(String fileName, Map<String, Object?> content) {
    File('${dir.path}/$fileName').writeAsStringSync(jsonEncode(content));
  }

  ArbCoverageReport analyze() =>
      analyzeArbDirectory(dir.path, templateFileName: 'intl_en.arb');

  group('analyzeArbDirectory — template integrity', () {
    test('throws when the directory does not exist', () {
      expect(
        () => analyzeArbDirectory(
          '${dir.path}/nope',
          templateFileName: 'intl_en.arb',
        ),
        throwsArgumentError,
      );
    });

    test('throws when the template file is missing', () {
      expect(analyze, throwsArgumentError);
    });

    test('throws a FormatException on malformed template JSON', () {
      File('${dir.path}/intl_en.arb').writeAsStringSync('not json');
      expect(analyze, throwsFormatException);
    });

    test('collects template message keys, ignoring @-metadata', () {
      writeArb('intl_en.arb', {
        '@@locale': 'en',
        'greeting': 'Hello',
        '@greeting': {'description': 'Greets the user'},
        'farewell': 'Bye',
        '@farewell': {'description': 'Sends the user off'},
      });

      final report = analyze();

      expect(report.templateKeys, {'greeting', 'farewell'});
      expect(report.keysMissingDescription, isEmpty);
    });

    test('flags template keys with no metadata or an empty description', () {
      writeArb('intl_en.arb', {
        'noMeta': 'value',
        'emptyDescription': 'value',
        '@emptyDescription': {'description': '   '},
        'fine': 'value',
        '@fine': {'description': 'Documented'},
      });

      final report = analyze();

      expect(report.keysMissingDescription, {'noMeta', 'emptyDescription'});
    });
  });

  group('analyzeArbDirectory — locale coverage', () {
    setUp(() {
      writeArb('intl_en.arb', {
        '@@locale': 'en',
        'greeting': 'Hello',
        '@greeting': {'description': 'Greets the user'},
        'farewell': 'Bye',
        '@farewell': {'description': 'Sends the user off'},
      });
    });

    test('partial coverage is reported as untranslated, not an error', () {
      writeArb('intl_de.arb', {'@@locale': 'de', 'greeting': 'Hallo'});

      final report = analyze();

      final de = report.locales.single;
      expect(de.fileName, 'intl_de.arb');
      expect(de.untranslatedKeys, {'farewell'});
      expect(de.unknownKeys, isEmpty);
      expect(report.hasUntranslated, isTrue);
      expect(report.hasUnknownKeys, isFalse);
    });

    test('keys absent from the template surface as unknown', () {
      writeArb('intl_de.arb', {
        '@@locale': 'de',
        'greeting': 'Hallo',
        'orphan': 'Waise',
      });

      final report = analyze();

      expect(report.locales.single.unknownKeys, {'orphan'});
      expect(report.hasUnknownKeys, isTrue);
    });

    test('locale is derived from the file name and cross-checked against '
        '@@locale', () {
      writeArb('intl_de.arb', {'@@locale': 'de', 'greeting': 'Hallo'});
      writeArb('intl_fr.arb', {'@@locale': 'de', 'greeting': 'Bonjour'});

      final report = analyze();

      final de = report.locales.firstWhere((l) => l.fileName == 'intl_de.arb');
      final fr = report.locales.firstWhere((l) => l.fileName == 'intl_fr.arb');
      expect(de.fileNameLocale, 'de');
      expect(de.declaredLocaleMatchesFileName, isTrue);
      expect(fr.fileNameLocale, 'fr');
      expect(
        fr.declaredLocaleMatchesFileName,
        isFalse,
        reason: '@@locale says de inside a file named fr',
      );
    });

    test('a file without @@locale passes the declaration check', () {
      writeArb('intl_de.arb', {'greeting': 'Hallo'});

      expect(analyze().locales.single.declaredLocaleMatchesFileName, isTrue);
    });

    test('describe() renders untranslated and unknown keys', () {
      writeArb('intl_de.arb', {
        '@@locale': 'de',
        'greeting': 'Hallo',
        'orphan': 'Waise',
      });

      final text = analyze().describe();

      expect(text, contains('intl_de.arb'));
      expect(text, contains('farewell'));
      expect(text, contains('orphan'));
    });
  });

  group('analyzeArbDirectory — locale token extraction', () {
    ArbCoverageReport analyzeWith(String template) =>
        analyzeArbDirectory(dir.path, templateFileName: template);

    test('a prefix containing underscores does not bleed into the '
        'locale (app_shell_de.arb → de)', () {
      writeArb('app_shell_en.arb', {
        '@@locale': 'en',
        'greeting': 'Hello',
        '@greeting': {'description': 'Greets the user'},
      });
      writeArb('app_shell_de.arb', {'@@locale': 'de', 'greeting': 'Hallo'});

      final de = analyzeWith('app_shell_en.arb').locales.single;

      expect(de.fileNameLocale, 'de');
      expect(
        de.declaredLocaleMatchesFileName,
        isTrue,
        reason: 'splitting on the first underscore would yield shell_de',
      );
    });

    test('a script subtag survives (intl_zh_Hant.arb → zh_Hant)', () {
      writeArb('intl_en.arb', {
        '@@locale': 'en',
        'greeting': 'Hello',
        '@greeting': {'description': 'Greets the user'},
      });
      writeArb('intl_zh_Hant.arb', {'@@locale': 'zh_Hant', 'greeting': '你好'});

      final zh = analyzeWith('intl_en.arb').locales.single;

      expect(zh.fileNameLocale, 'zh_Hant');
      expect(zh.declaredLocaleMatchesFileName, isTrue);
    });
  });
}
