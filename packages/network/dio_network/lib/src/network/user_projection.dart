/// A person's account name, display name and avatar, as a server row embeds
/// them.
typedef UserProjection = ({
  String? username,
  String? displayName,
  String? avatarUrl,
});

/// Reads the account name, display name and avatar out of an embedded `user`
/// projection, `{ id, username, profile: { avatarUrl, displayName } }`.
///
/// The event roster and the household list embed the same projection, so
/// both adapters read it here (#304). [row] names the row it came from in
/// the error messages: `attendee`, `member`.
///
/// A null `user` has no account to take them from, so all three are null: a
/// guest on an event roster, or a member row from a server that sent no
/// projection. An account that has set no profile has a username and neither
/// of the others. A projection whose shape is wrong is a contract breach and
/// throws, as the role projection does.
UserProjection readUserProjection(Object? projection, {required String row}) {
  if (projection == null) {
    return (username: null, displayName: null, avatarUrl: null);
  }
  if (projection is! Map<String, dynamic>) {
    throw FormatException(
      '$row "user" is ${projection.runtimeType}, expected an object or '
      'null',
    );
  }
  final profile = projection['profile'];
  if (profile != null && profile is! Map<String, dynamic>) {
    throw FormatException(
      '$row "user" profile is ${profile.runtimeType}, expected an '
      'object or null',
    );
  }
  final fields = profile as Map<String, dynamic>?;
  return (
    // Read strictly: an account always has a username.
    username: projection['username'] as String,
    displayName: fields?['displayName'] as String?,
    avatarUrl: fields?['avatarUrl'] as String?,
  );
}

/// Reads the role name out of an embedded role join projection,
/// `{ role: { name } }`, as a [row] (`member`, `attendee`) embeds it.
///
/// A null projection is a row with no role binding, which the models
/// represent as a null role. A projection whose shape is wrong is a contract
/// breach and throws: it must not be laundered into the role enum's `unknown`,
/// which would make a parsing failure indistinguishable from a custom server
/// role. The caller passes the name to its enum's `fromWire`.
String? readRoleName(Object? projection, {required String row}) {
  if (projection == null) return null;
  if (projection is! Map<String, dynamic>) {
    throw FormatException(
      '$row "role" is ${projection.runtimeType}, expected the embedded '
      'role projection',
    );
  }
  final role = projection['role'];
  if (role is! Map<String, dynamic>) {
    throw FormatException(
      '$row "role" projection is missing its nested "role" object, got '
      '${role.runtimeType}',
    );
  }
  final name = role['name'];
  if (name is! String) {
    throw FormatException(
      '$row role is missing a "name", got ${name.runtimeType}',
    );
  }
  return name;
}
