/// The values a settings group's form last took from the server (#807), and
/// the rule for taking new ones.
///
/// `revision` moves whenever the server's settings were read or a save of
/// either group landed. A form takes the new values when its own save just
/// landed, or when it holds no unsaved changes, so another group's save never
/// discards the user's edits ([takes]).
///
/// Taking them is not an edit. reactive_forms delivers the value changes of
/// the reset that takes them asynchronously, after the reset, so they are
/// told apart by their value ([isEcho]): a change to anything else is the
/// user's, and ends the echo.
class SettingsSeed<T> {
  /// Starts at [values], the form's first, which are no echo: a form's
  /// first values are set, not reset.
  SettingsSeed(this._values, {bool Function(T a, T b)? equals})
    : _equals = equals ?? _same;

  /// Whether a form whose widget moves from [previousRevision] to [revision]
  /// takes the server's values: when they moved and its own save just landed
  /// ([saved]), or it holds nothing [unsaved] against the values it had.
  static bool takes({
    required int revision,
    required int previousRevision,
    required bool saved,
    required bool unsaved,
  }) => revision != previousRevision && (saved || !unsaved);

  static bool _same(Object? a, Object? b) => a == b;

  final bool Function(T a, T b) _equals;
  T _values;
  bool _echoing = false;

  /// The values last taken.
  T get values => _values;

  /// Takes [values]. The value changes that echo them are not edits.
  void take(T values) {
    _values = values;
    _echoing = true;
  }

  /// Whether [value], from a value change, is the echo of the last [take]
  /// rather than the user's edit.
  bool isEcho(T value) {
    if (_echoing && _equals(value, _values)) return true;
    _echoing = false;
    return false;
  }
}
