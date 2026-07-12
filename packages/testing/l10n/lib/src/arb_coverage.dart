import 'dart:convert';
import 'dart:io';

/// Analyzes an ARB directory against its template file (issue #33).
///
/// Reads [templateFileName] (e.g. `intl_en.arb`) and every other `*.arb`
/// file in [arbDirPath], returning an [ArbCoverageReport]. This function
/// only produces data — asserting the repo policy on it is the calling
/// test's job, which keeps hard-fail vs report-only decisions (partial
/// coverage is *allowed*) in one visible place per package.
///
/// Throws an [ArgumentError] when the directory or template is missing,
/// and a [FormatException] when any ARB file is not valid JSON — a
/// broken template is a hard failure regardless of policy.
ArbCoverageReport analyzeArbDirectory(
  String arbDirPath, {
  required String templateFileName,
}) {
  final dir = Directory(arbDirPath);
  if (!dir.existsSync()) {
    throw ArgumentError.value(arbDirPath, 'arbDirPath', 'does not exist');
  }
  final templateFile = File('${dir.path}/$templateFileName');
  if (!templateFile.existsSync()) {
    throw ArgumentError.value(
      templateFileName,
      'templateFileName',
      'not found in $arbDirPath',
    );
  }

  final template = _parseArb(templateFile);
  final templateKeys = _messageKeys(template);
  final keysMissingDescription = <String>{
    for (final key in templateKeys)
      if (!_hasDescription(template, key)) key,
  };

  // The locale token in an ARB file name is whatever follows the shared
  // prefix — derived from the template rather than by splitting on an
  // underscore, so prefixes that themselves contain underscores
  // (`app_shell_de.arb` → `de`) and locales that contain them
  // (`intl_zh_Hant.arb` → `zh_Hant`) both resolve correctly.
  final templateLocale =
      (template['@@locale'] as String?) ??
      _localeAfterLastUnderscore(templateFileName);
  final prefix = _arbPrefix(templateFileName, templateLocale);

  final locales = <ArbLocaleCoverage>[];
  final arbFiles =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.arb'))
          .where((f) => _basename(f.path) != templateFileName)
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in arbFiles) {
    final content = _parseArb(file);
    final keys = _messageKeys(content);
    final fileName = _basename(file.path);
    locales.add(
      ArbLocaleCoverage(
        fileName: fileName,
        fileNameLocale: _localeFromFileName(fileName, prefix),
        declaredLocale: content['@@locale'] as String?,
        untranslatedKeys: templateKeys.difference(keys),
        unknownKeys: keys.difference(templateKeys),
      ),
    );
  }

  return ArbCoverageReport(
    templateFileName: templateFileName,
    templateKeys: templateKeys,
    keysMissingDescription: keysMissingDescription,
    locales: List.unmodifiable(locales),
  );
}

/// Coverage data for the ARB files of one l10n package.
class ArbCoverageReport {
  const ArbCoverageReport({
    required this.templateFileName,
    required this.templateKeys,
    required this.keysMissingDescription,
    required this.locales,
  });

  /// The template file the other ARBs were compared against.
  final String templateFileName;

  /// Message keys (non-`@`) defined by the template.
  final Set<String> templateKeys;

  /// Template keys with no `@key` metadata or an empty `description`.
  ///
  /// Repo policy: hard failure. Descriptions are translator context and
  /// the documentation surface for every user-facing string.
  final Set<String> keysMissingDescription;

  /// Per-locale coverage for every non-template ARB, sorted by path.
  final List<ArbLocaleCoverage> locales;

  /// Whether any non-template file carries keys the template lacks.
  bool get hasUnknownKeys => locales.any((l) => l.unknownKeys.isNotEmpty);

  /// Whether any non-template file is missing template keys.
  ///
  /// Repo policy: allowed (gen-l10n inherits missing messages from the
  /// template) — report for visibility, don't fail.
  bool get hasUntranslated => locales.any((l) => l.untranslatedKeys.isNotEmpty);

  /// Human-readable summary, intended for test output.
  String describe() {
    final buffer = StringBuffer()
      ..writeln(
        'ARB coverage against $templateFileName '
        '(${templateKeys.length} keys):',
      );
    if (keysMissingDescription.isNotEmpty) {
      buffer.writeln(
        '  template keys missing a description: '
        '${(keysMissingDescription.toList()..sort()).join(', ')}',
      );
    }
    if (locales.isEmpty) {
      buffer.writeln('  no non-template locales present.');
    }
    for (final locale in locales) {
      buffer.writeln('  ${locale.fileName}:');
      if (locale.unknownKeys.isNotEmpty) {
        buffer.writeln(
          '    unknown keys (not in template): '
          '${(locale.unknownKeys.toList()..sort()).join(', ')}',
        );
      }
      if (locale.untranslatedKeys.isNotEmpty) {
        buffer.writeln(
          '    untranslated (inherited from template): '
          '${(locale.untranslatedKeys.toList()..sort()).join(', ')}',
        );
      } else if (locale.unknownKeys.isEmpty) {
        buffer.writeln('    complete.');
      }
    }
    return buffer.toString();
  }
}

/// Coverage data for a single non-template ARB file.
class ArbLocaleCoverage {
  const ArbLocaleCoverage({
    required this.fileName,
    required this.fileNameLocale,
    required this.declaredLocale,
    required this.untranslatedKeys,
    required this.unknownKeys,
  });

  /// The ARB file name, e.g. `intl_de.arb`.
  final String fileName;

  /// The locale implied by the file name (`intl_de.arb` → `de`), or null
  /// when the name doesn't follow the `<prefix>_<locale>.arb` shape.
  final String? fileNameLocale;

  /// The `@@locale` value declared inside the file, if any.
  final String? declaredLocale;

  /// Template keys this file does not translate (allowed — inherited).
  final Set<String> untranslatedKeys;

  /// Keys this file defines that the template does not (hard failure —
  /// dead strings that gen-l10n silently ignores).
  final Set<String> unknownKeys;

  /// True when `@@locale` is absent or agrees with the file name.
  bool get declaredLocaleMatchesFileName =>
      declaredLocale == null ||
      fileNameLocale == null ||
      declaredLocale == fileNameLocale;
}

Map<String, dynamic> _parseArb(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  // jsonDecode returns Map<String, dynamic> at runtime; a bare `is Map`
  // check is required — `is Map<String, Object?>` fails on that type due
  // to generic invariance, which would reject every valid ARB file.
  if (decoded is! Map) {
    throw FormatException('${file.path} is not a JSON object');
  }
  return Map<String, dynamic>.from(decoded);
}

Set<String> _messageKeys(Map<String, dynamic> arb) => {
  for (final key in arb.keys.where((k) => !k.startsWith('@'))) key,
};

bool _hasDescription(Map<String, dynamic> arb, String key) {
  final meta = arb['@$key'];
  if (meta is! Map) return false;
  final description = meta['description'];
  return description is String && description.trim().isNotEmpty;
}

// Separator-agnostic: Directory.listSync yields platform-separated paths
// (`\` on Windows) while the template path is built with `/`, so split on
// either — the helper is presented as reusable pure-Dart support.
String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

/// The shared ARB file-name prefix implied by [templateFileName] and its
/// locale (e.g. `intl_en.arb` + `en` → `intl_`). Falls back to
/// everything up to and including the last underscore when the template
/// locale is unknown or doesn't suffix the name.
String _arbPrefix(String templateFileName, String? templateLocale) {
  const ext = '.arb';
  if (templateLocale != null &&
      templateFileName.endsWith('$templateLocale$ext')) {
    return templateFileName.substring(
      0,
      templateFileName.length - templateLocale.length - ext.length,
    );
  }
  final base = templateFileName.substring(
    0,
    templateFileName.length - ext.length,
  );
  final underscore = base.lastIndexOf('_');
  return underscore == -1 ? '' : base.substring(0, underscore + 1);
}

/// The locale token of [fileName] = what remains after stripping [prefix]
/// and the `.arb` extension. Null when the name doesn't fit the shape.
String? _localeFromFileName(String fileName, String prefix) {
  const ext = '.arb';
  if (!fileName.endsWith(ext)) return null;
  if (prefix.isNotEmpty && !fileName.startsWith(prefix)) return null;
  final locale = fileName.substring(
    prefix.length,
    fileName.length - ext.length,
  );
  return locale.isEmpty ? null : locale;
}

String? _localeAfterLastUnderscore(String fileName) {
  final base = fileName.substring(0, fileName.length - 4);
  final underscore = base.lastIndexOf('_');
  if (underscore == -1 || underscore == base.length - 1) return null;
  return base.substring(underscore + 1);
}
