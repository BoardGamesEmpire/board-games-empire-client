import 'package:freezed_annotation/freezed_annotation.dart';

part 'language_link.freezed.dart';

/// Where a language link stands in an admin's review of it.
///
/// Mirrors the backend's `LanguageLinkStatus` enum
/// (`prisma/models/system/language.prisma` in `board-games-empire-backend`).
enum LanguageLinkStatus {
  /// Linked to a language tag.
  resolved,

  /// A registered language that is not in the server's vocabulary yet.
  /// Accepting it adds the language and its tag, and links it.
  pending,

  /// The server could not match it to a tag on its own, so it needs an admin
  /// to link it to one.
  unresolved,

  /// Dismissed by an admin. Interviews and imports leave it alone.
  ignored,

  /// A status this client does not know. Shown, never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static LanguageLinkStatus fromWire(String name) => switch (name) {
    'Resolved' => LanguageLinkStatus.resolved,
    'Pending' => LanguageLinkStatus.pending,
    'Unresolved' => LanguageLinkStatus.unresolved,
    'Ignored' => LanguageLinkStatus.ignored,
    _ => LanguageLinkStatus.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    LanguageLinkStatus.resolved => 'Resolved',
    LanguageLinkStatus.pending => 'Pending',
    LanguageLinkStatus.unresolved => 'Unresolved',
    LanguageLinkStatus.ignored => 'Ignored',
    LanguageLinkStatus.unknown => throw StateError(
      'LanguageLinkStatus.unknown has no wire name',
    ),
  };
}

/// How a DataGateway spells a language value.
///
/// Mirrors the backend's `LanguageCodeFormat` enum
/// (`prisma/models/system/language.prisma` in `board-games-empire-backend`).
enum LanguageCodeFormat {
  iso6391,
  iso6393,
  ietfBcp47,
  languageName,
  nativeName,

  /// A format this client does not know, or none sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static LanguageCodeFormat fromWire(String? name) => switch (name) {
    'Iso6391' => LanguageCodeFormat.iso6391,
    'Iso6393' => LanguageCodeFormat.iso6393,
    'IetfBcp47' => LanguageCodeFormat.ietfBcp47,
    'Name' => LanguageCodeFormat.languageName,
    'NativeName' => LanguageCodeFormat.nativeName,
    _ => LanguageCodeFormat.unknown,
  };
}

/// A language tag as a link names it and the catalogue lists it: enough to say
/// which one, and to show it.
@freezed
abstract class LanguageTagRef with _$LanguageTagRef {
  const factory LanguageTagRef({
    required String id,

    /// The canonical BCP 47 tag, such as `pt-BR`.
    required String tag,

    /// The tag's display name, such as `Portuguese (Brazil)`.
    required String name,
  }) = _LanguageTagRef;
}

/// How one value a DataGateway uses for a language, such as `Czech` or `cs`,
/// maps to the server's language tags (#457).
///
/// An interview or an import writes one for each value it meets. The ones the
/// server could not match on its own are the worklist an admin reviews.
///
/// The server's other columns are not read: which DataGateway it belongs to
/// (the caller already named it), the origin of the value, the supplied ISO 639
/// codes, and when the link was made or changed. Reviewing a link needs none of
/// them, and a field that is read is one more way for a row to fail to parse.
@freezed
abstract class LanguageLink with _$LanguageLink {
  const factory LanguageLink({
    required String id,

    /// The DataGateway's own value, normalized by the server: a BCP 47 tag
    /// canonicalized, an ISO code lowercased, a name's spaces collapsed.
    required String value,

    /// How [value] is spelled. The same value can be listed once per format,
    /// such as `en` as a tag and as an ISO code, so it takes both to say which
    /// link this is.
    @Default(LanguageCodeFormat.unknown) LanguageCodeFormat format,
    required LanguageLinkStatus status,

    /// The tag it is linked to. Set only while [status] is
    /// [LanguageLinkStatus.resolved].
    LanguageTagRef? tag,

    /// What the DataGateway supplied beside the value, kept so an admin can
    /// tell what it meant without interviewing again. Each is null when it
    /// supplied nothing.
    String? suppliedName,
    String? suppliedNativeName,
    String? suppliedIetfTag,
  }) = _LanguageLink;
}
