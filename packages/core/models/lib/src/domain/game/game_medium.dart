enum GameMedium {
  physical,
  digital;

  static GameMedium fromJson(String value) => switch (value) {
    'Physical' => physical,
    'Digital' => digital,
    _ => throw FormatException('Unknown GameMedium: $value'),
  };

  String toJson() => switch (this) {
    physical => 'Physical',
    digital => 'Digital',
  };
}
