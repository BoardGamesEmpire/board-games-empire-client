enum TimeMeasure {
  minutes,
  hours,
  days,
  weeks,
  months,
  years;

  static TimeMeasure fromJson(String value) => switch (value) {
    'Minutes' => minutes,
    'Hours' => hours,
    'Days' => days,
    'Weeks' => weeks,
    'Months' => months,
    'Years' => years,
    _ => throw FormatException('Unknown TimeMeasure: $value'),
  };

  String toJson() => switch (this) {
    minutes => 'Minutes',
    hours => 'Hours',
    days => 'Days',
    weeks => 'Weeks',
    months => 'Months',
    years => 'Years',
  };
}
