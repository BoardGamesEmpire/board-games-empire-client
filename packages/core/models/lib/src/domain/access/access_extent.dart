/// How much of a resource type the caller may act on, as the server answers
/// it (#456).
enum AccessExtent {
  /// Every resource of the type.
  all,

  /// Some resources of the type. The server decides which, per resource, so
  /// the client never re-checks a condition itself.
  some,

  /// No resource of the type.
  none;

  /// Whether the action is open at all: `all` or `some`.
  bool get allows => this != none;
}

/// An action the server reports an [AccessExtent] for (#456).
enum AccessAction { create, read, update, delete, manage }
