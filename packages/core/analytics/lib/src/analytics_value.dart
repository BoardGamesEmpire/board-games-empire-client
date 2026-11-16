import 'package:meta/meta.dart';

/// Which variant an [AnalyticsValue] is. The catalog snapshot records it by
/// name, so renaming a member is a catalog change.
enum AnalyticsValueKind {
  /// An [AnalyticsInt].
  integer,

  /// An [AnalyticsDouble].
  decimal,

  /// An [AnalyticsBool].
  boolean,

  /// An [AnalyticsToken].
  token,

  /// An [AnalyticsId].
  id,
}

/// A property value on an analytics event (#17).
///
/// There is no string variant, on purpose. A free-text property is how a
/// game title or a search query reaches a third party, and #165 showed that
/// a written rule with no mechanism behind it does not hold here. Text can
/// only travel as a member of a closed vocabulary ([AnalyticsToken]) or as
/// an opaque server id ([AnalyticsId]); anything else cannot be expressed.
@immutable
sealed class AnalyticsValue {
  const AnalyticsValue();

  /// The JSON-safe value a transport sends.
  Object get wireValue;

  /// Which variant this is.
  AnalyticsValueKind get kind;
}

/// A whole number in JSON's safe-integer range, ±(2^53 − 1).
///
/// Anything outside it throws [ArgumentError]: a JavaScript reader parses
/// it with lost precision and a web build cannot hold it exactly, so it
/// would arrive as a different number rather than be rejected.
final class AnalyticsInt extends AnalyticsValue {
  AnalyticsInt(this.value) {
    if (value > maxSafe || value < -maxSafe) {
      throw ArgumentError.value(
        value,
        'value',
        'is outside the JSON safe-integer range',
      );
    }
  }

  /// 2^53 − 1, the largest integer a double holds exactly.
  static const maxSafe = 9007199254740991;

  final int value;

  @override
  Object get wireValue => value;

  @override
  AnalyticsValueKind get kind => AnalyticsValueKind.integer;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is AnalyticsInt &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// A finite floating-point number.
///
/// NaN and the infinities throw [ArgumentError]: JSON cannot carry them, and
/// a sink would reject the whole batch they arrived in.
final class AnalyticsDouble extends AnalyticsValue {
  AnalyticsDouble(this.value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'must be finite');
    }
  }

  final double value;

  @override
  Object get wireValue => value;

  @override
  AnalyticsValueKind get kind => AnalyticsValueKind.decimal;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is AnalyticsDouble &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// A boolean.
final class AnalyticsBool extends AnalyticsValue {
  // The class is the value's name, so `AnalyticsBool(true)` reads as
  // plainly as `AnalyticsInt(3)`; a named parameter would add nothing.
  // ignore: avoid_positional_boolean_parameters
  const AnalyticsBool(this.value);

  final bool value;

  @override
  Object get wireValue => value;

  @override
  AnalyticsValueKind get kind => AnalyticsValueKind.boolean;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is AnalyticsBool &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// A member of a closed vocabulary, sent as the enum member's name.
///
/// The vocabulary is a Dart enum, so the type closes it. The constructor
/// still checks that [value] is one of `vocabulary`'s members and throws
/// [ArgumentError] otherwise, at runtime rather than through an assert,
/// which release builds drop. An enum's `unknown` sentinel is a member like
/// any other and is accepted.
///
/// The token keeps its own unmodifiable copy of `vocabulary`, so a caller
/// that changes its list afterwards cannot change the token.
final class AnalyticsToken<T extends Enum> extends AnalyticsValue {
  AnalyticsToken(this.value, {required List<T> vocabulary})
    : _vocabulary = List.unmodifiable(vocabulary) {
    if (!_vocabulary.contains(value)) {
      throw ArgumentError.value(
        value,
        'value',
        'is not a member of its declared vocabulary',
      );
    }
  }

  final T value;
  final List<T> _vocabulary;

  /// Every member's name, in declaration order.
  List<String> get vocabularyNames => [
    for (final member in _vocabulary) member.name,
  ];

  @override
  Object get wireValue => value.name;

  @override
  AnalyticsValueKind get kind => AnalyticsValueKind.token;

  // Not runtimeType: it carries the type argument, so an
  // AnalyticsToken<Enum> and an AnalyticsToken<GameMedium> holding the same
  // member would differ. The class is final, so `is` is exact. The value
  // decides equality: it is what goes on the wire, and an enum member
  // belongs to one enum. The snapshot test checks vocabularies.
  @override
  bool operator ==(Object other) =>
      other is AnalyticsToken && other.value == value;

  @override
  int get hashCode => Object.hash(AnalyticsToken, value);
}

/// An opaque server id, sent as-is.
///
/// The server mints every id with Prisma's `cuid(2)`, and the client mints
/// cuid2 at the default length of 24; 32 is the most that package allows.
/// Anything that isn't a lowercase letter followed by 23 to 31 lowercase
/// letters or digits throws [ArgumentError] here, at construction.
///
/// The shape is a guard, not proof: a lowercase run-together word of 24 or
/// more characters still passes. The main control is this type's name at
/// the call site, where review sees what is being passed as an id.
final class AnalyticsId extends AnalyticsValue {
  AnalyticsId(this.value) {
    if (!_shape.hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'is not an opaque id');
    }
  }

  static final _shape = RegExp(r'^[a-z][a-z0-9]{23,31}$');

  final String value;

  @override
  Object get wireValue => value;

  @override
  AnalyticsValueKind get kind => AnalyticsValueKind.id;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is AnalyticsId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}
