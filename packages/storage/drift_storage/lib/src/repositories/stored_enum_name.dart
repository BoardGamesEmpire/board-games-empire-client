/// What an enum column holds for a value this client could not read. No
/// enum has it as a wire name, so each one's `fromWire` reads it back as
/// `unknown`, as it does any other name it doesn't know.
const String unknownEnumName = 'Unknown';

/// The name an enum column stores for [value]: its wire name, or
/// [unknownEnumName] for [unknown], which stands for a name this client could
/// not read and so has no wire name of its own. The name the server sent is
/// not kept.
String storedEnumName<T extends Enum>(
  T value,
  T unknown,
  String Function(T) toWire,
) => value == unknown ? unknownEnumName : toWire(value);
