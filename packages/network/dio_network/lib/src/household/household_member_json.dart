import 'package:models/domain.dart';

import '../network/user_projection.dart';

/// Maps a server member payload to the domain [HouseholdMember].
///
/// The household list embeds its members in this shape, and so does the
/// `member` in the answers to the member routes (#480, #483), so both
/// sources read it here.
///
/// The `role` field needs unwrapping, not just reading: the server embeds
/// the join row with the role nested inside it —
/// `role: { …join…, role: { id, name } }` — while the domain model carries
/// a [HouseholdRole] resolved from the role **name**.
///
/// Handing that object to `HouseholdMember.fromJson` would not fail. The
/// generated decoder calls `$enumDecodeNullable(..., unknownValue:
/// HouseholdRole.unknown)`, a Map matches no entry in the enum map, and
/// every member would come back `unknown` — silently, with `isOwner` and
/// `isAdmin` false for everyone. Unwrapping here keeps
/// [HouseholdRole.unknown] meaning what it was designed to mean: a
/// server-defined role name this client does not recognise.
///
/// The `user` field is unwrapped too: the list embeds the member's account
/// as `user: { id, username, profile: { avatarUrl, displayName } }`, the
/// projection the event roster embeds, and [readUserProjection] reads it
/// for both (#304). An absent or null `user` leaves the member nameless
/// rather than failing the page, and one of the wrong shape throws.
HouseholdMember mapHouseholdMember(Map<String, dynamic> json) {
  final user = readUserProjection(json['user'], row: 'member');
  return HouseholdMember(
    id: json['id'] as String,
    userId: json['userId'] as String,
    householdId: json['householdId'] as String,
    // Read strictly, not `?? true`: this is a non-nullable server column,
    // and defaulting a *sharing* flag to its permissive value on a payload
    // we could not read is the wrong direction to fail in.
    showAllGames: json['showAllGames'] as bool,
    role: mapHouseholdRole(json['role']),
    username: user.username,
    displayName: user.displayName,
    avatarUrl: user.avatarUrl,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

/// Reads the role name out of the embedded join projection.
///
/// A null projection is a member with no role binding, which the model
/// represents as a null role. A projection whose shape is wrong is a
/// contract breach and throws — it must not be laundered into
/// [HouseholdRole.unknown], which would make a parsing failure
/// indistinguishable from a custom server role.
HouseholdRole? mapHouseholdRole(Object? projection) {
  if (projection == null) return null;
  if (projection is! Map<String, dynamic>) {
    throw FormatException(
      'member "role" is ${projection.runtimeType}, expected the embedded '
      'role projection',
    );
  }
  final role = projection['role'];
  if (role is! Map<String, dynamic>) {
    throw FormatException(
      'member "role" projection is missing its nested "role" object, got '
      '${role.runtimeType}',
    );
  }
  final name = role['name'];
  if (name is! String) {
    throw FormatException(
      'member role is missing a "name", got ${name.runtimeType}',
    );
  }
  return HouseholdRole.fromWire(name);
}
