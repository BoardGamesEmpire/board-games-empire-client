/// How much harm a permission can do if its key leaks (#1028).
enum RiskLevel {
  low,
  medium,
  high,
  critical,

  /// A level this client does not know, or none at all.
  unknown;

  /// Resolves the server's `riskLevel`, which is capitalised on the wire,
  /// degrading to [unknown].
  static RiskLevel fromWire(String? value) => switch (value) {
    'Low' => RiskLevel.low,
    'Medium' => RiskLevel.medium,
    'High' => RiskLevel.high,
    'Critical' => RiskLevel.critical,
    _ => RiskLevel.unknown,
  };
}
