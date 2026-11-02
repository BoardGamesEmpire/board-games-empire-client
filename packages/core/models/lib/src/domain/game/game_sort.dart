/// The order a list of games comes in.
///
/// Each value names an order, not a column. [wire] is what the server's
/// `GET /games?sort=` takes (backend#959), and what a screen can keep in its
/// URL to say which order it shows.
///
/// Not named `toJson` / `fromJson`, for the reason `content_type.dart` gives.
enum GameSort {
  /// By title, then id where titles tie. The server's default.
  title,

  /// The games most recently added first.
  newest;

  /// The name the server's `sort` query parameter takes.
  String get wire => switch (this) {
    title => 'title',
    newest => 'newest',
  };

  /// The sort [value] names, or null for anything else, including a name in
  /// the wrong case: the server refuses those too.
  static GameSort? fromWire(String? value) => switch (value) {
    'title' => title,
    'newest' => newest,
    _ => null,
  };
}
