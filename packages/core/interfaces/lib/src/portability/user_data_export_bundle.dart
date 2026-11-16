import 'dart:convert';
import 'dart:typed_data';

/// An assembled user-data export, ready to be written out (#48).
///
/// Holds the envelope `UserDataExportBundler` (in `package:di`) built and
/// knows how it is serialised and named, so every platform's writer
/// produces the same file.
///
/// [json] is an envelope as `UserDataExportBundler.assemble` builds it:
/// [fileName] relies on its `serverName` and `exportedAt`, and throws on
/// a [json] that lacks them or holds a malformed timestamp.
final class UserDataExportBundle {
  const UserDataExportBundle({
    required this.json,
    required this.unconfirmedKeys,
  });

  // Keeps the slug, and so the file name, well inside the 255-byte limit
  // most file systems enforce.
  static const int _maxSlugLength = 60;

  /// The envelope, as documented on `UserDataExportBundler`.
  final Map<String, Object?> json;

  /// The keys of the categories whose data is this device's copy, not
  /// confirmed by the server, in registration order.
  final List<String> unconfirmedKeys;

  /// The file's bytes: UTF-8 JSON indented by two spaces, ending in a
  /// newline.
  Uint8List toBytes() =>
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(json)}\n');

  /// `bge-export-<server name slug>-<yyyy-MM-dd-HHmm, UTC>.json`.
  String get fileName {
    final slug = (json['serverName']! as String)
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final capped = slug.length > _maxSlugLength
        ? slug.substring(0, _maxSlugLength).replaceAll(RegExp(r'-+$'), '')
        : slug;
    final exportedAt = DateTime.parse(json['exportedAt']! as String).toUtc();

    String pad(int value, [int width = 2]) =>
        value.toString().padLeft(width, '0');

    final date =
        '${pad(exportedAt.year, 4)}-${pad(exportedAt.month)}-'
        '${pad(exportedAt.day)}';
    final time = '${pad(exportedAt.hour)}${pad(exportedAt.minute)}';
    return 'bge-export-${capped.isEmpty ? 'server' : capped}-$date-$time.json';
  }
}
