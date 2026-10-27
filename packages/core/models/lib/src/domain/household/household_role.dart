import 'package:freezed_annotation/freezed_annotation.dart';

/// Household membership role.
///
/// Maps to the server-side `Role.name` string surfaced through the
/// `HouseholdRole` join. Wire format mirrors the household-prefixed
/// entries of the server `SystemRole` enum.
///
/// Server deployments are free to define custom roles whose names do
/// not match a known value here. Such values deserialize to [unknown]
/// via `@JsonKey(unknownEnumValue: HouseholdRole.unknown)` on the
/// consuming `HouseholdMember.role` field, allowing the client to
/// degrade gracefully rather than throw.
///
/// See: `prisma/models/permissions/role.prisma` in
/// `board-games-empire-backend`.
enum HouseholdRole {
  @JsonValue('HouseholdOwner')
  householdOwner,
  @JsonValue('HouseholdAdmin')
  householdAdmin,
  @JsonValue('HouseholdMember')
  householdMember,
  @JsonValue('HouseholdGuest')
  householdGuest,

  /// Fallback when the server returns a role name not in the known set.
  /// Never sent back to the server.
  unknown;

  /// Resolves a server role **name** to its binding, degrading to [unknown]
  /// for a name this client does not know.
  ///
  /// Deployments may define custom roles, so an unrecognized name is a
  /// supported outcome rather than an error — this is the single purpose of
  /// [unknown]. Callers reading an embedded role projection must unwrap it to
  /// the name first: handing this method anything other than a role name
  /// would degrade a *shape* mismatch into a plausible-looking [unknown],
  /// which is precisely the silent failure this method exists to keep out of
  /// the domain.
  static HouseholdRole fromWire(String name) => switch (name) {
    'HouseholdOwner' => HouseholdRole.householdOwner,
    'HouseholdAdmin' => HouseholdRole.householdAdmin,
    'HouseholdMember' => HouseholdRole.householdMember,
    'HouseholdGuest' => HouseholdRole.householdGuest,
    _ => HouseholdRole.unknown,
  };

  /// The server's role name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    HouseholdRole.householdOwner => 'HouseholdOwner',
    HouseholdRole.householdAdmin => 'HouseholdAdmin',
    HouseholdRole.householdMember => 'HouseholdMember',
    HouseholdRole.householdGuest => 'HouseholdGuest',
    HouseholdRole.unknown => throw StateError(
      'HouseholdRole.unknown has no wire name',
    ),
  };

  /// Whether this role may create an event in its household (#499). An
  /// owner, an admin or a member may. A guest lacks
  /// `create:event:household`, and the server answers its create with 403.
  /// [unknown] may not either: a role this client can't read is not one it
  /// can vouch for.
  bool get mayCreateEvents => switch (this) {
    HouseholdRole.householdOwner ||
    HouseholdRole.householdAdmin ||
    HouseholdRole.householdMember => true,
    HouseholdRole.householdGuest || HouseholdRole.unknown => false,
  };
}
