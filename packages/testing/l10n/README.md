# l10n_test_support

Shared, pure-Dart ARB verification helpers for the localization convention
established by issue #33. Every package that owns an `l10n.yaml` (currently
`app_shell` and `features/auth`) adds this as a **dev dependency** and runs
the same coverage check over its `lib/l10n` directory.

## Policy enforced

- **Template integrity (hard-fail):** the template ARB (`intl_en.arb`) must
  exist, parse, and give every message key an `@key` entry with a non-empty
  `description`.
- **No orphan keys (hard-fail):** non-template ARB files may not contain
  keys absent from the template — those are dead strings that gen-l10n
  silently ignores.
- **Locale declaration (hard-fail):** when a non-template file declares
  `@@locale`, it must match the locale in its file name.
- **Partial coverage (allowed):** missing translations in non-template
  files are **not** failures — gen-l10n inherits them from the template at
  generation time. They are surfaced in the report (and in each package's
  gitignored `lib/l10n/untranslated.txt` via `untranslated-messages-file`)
  so gaps stay visible without blocking contributors.

## Usage

```dart
import 'package:l10n_test_support/l10n_test_support.dart';
import 'package:test/test.dart';

void main() {
  test('ARB coverage', () {
    final report = analyzeArbDirectory(
      'lib/l10n',
      templateFileName: 'intl_en.arb',
    );

    expect(report.keysMissingDescription, isEmpty);
    for (final locale in report.locales) {
      expect(locale.unknownKeys, isEmpty);
      expect(locale.declaredLocaleMatchesFileName, isTrue);
    }
    // Partial coverage is policy — report, don't fail.
    // ignore: avoid_print
    if (report.hasUntranslated) print(report.describe());
  });
}
```
