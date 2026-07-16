/// The scalar fields shared by every user representation the client
/// parses, regardless of which endpoint family produced it.
///
/// Two concrete contracts implement this:
///
/// - [AuthUser] — the shape returned by `/api/auth/*` (BetterAuth), which
///   names the display field `name` on the wire and omits BGE-specific
///   fields (`role`, `isServiceAccount`).
/// - `User` — the canonical BGE domain user returned by `/api/user/*` and
///   embedded in relations (household member → user, etc.), which names
///   the field `username` and carries the BGE-only fields.
///
/// Both are camelCase on the wire (only the well-known discovery document
/// is snake_case). Code that needs only the common identity/profile fields
/// should type against [UserBase] and stay agnostic about which endpoint
/// produced the value; code that needs `role`/`isServiceAccount` must use
/// the concrete `User`.
///
/// This is an interface, not a base with fields: the concrete types are
/// `freezed` classes that `implements UserBase`, so `freezed` generates the
/// getters that satisfy this contract while each keeps its own JSON
/// mapping.
abstract interface class UserBase {
  /// Stable user id (cuid2).
  String get id;

  /// Display username. Sourced from the wire `name` field on [AuthUser]
  /// and from `username` on `User`.
  String get username;

  /// Account email.
  String get email;

  /// Whether the email has been verified.
  bool get emailVerified;

  /// Avatar/profile image URL, if set. (Backend field `image`; there is no
  /// separate `avatar`/`profileImage`.)
  String? get image;

  String? get firstName;
  String? get lastName;

  /// Moderation flags.
  bool? get banned;
  String? get banReason;
  DateTime? get banExpires;

  /// Whether this is an anonymous (not-yet-linked) account.
  bool? get isAnonymous;

  /// Whether two-factor auth is enabled on the account.
  bool? get twoFactorEnabled;

  DateTime get createdAt;
  DateTime get updatedAt;
}
