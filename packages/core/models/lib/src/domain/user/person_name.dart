/// The name to show for a person the server embeds as a `user` projection:
/// their display name, else their username, else null (#304).
///
/// Both are trimmed, and an empty or whitespace-only value counts as absent,
/// as `UserProfile.displayName` treats them (#183): the server accepts a
/// display name of spaces, and showing it would leave a blank row. The
/// server requires a username, so null means only that none is cached.
///
/// The event roster and the household roster both name people with this,
/// so one person reads the same on both.
String? personName({String? displayName, String? username}) =>
    _present(displayName) ?? _present(username);

/// [text] trimmed, or null where nothing is left.
String? _present(String? text) {
  final trimmed = text?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
