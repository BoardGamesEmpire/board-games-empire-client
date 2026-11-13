/// [wire] when it is a string with something in it, else null: absent,
/// null, not a string, or empty.
///
/// The adapters read optional text this way, image URLs above all: an empty
/// URL kept would stand in front of the picture after it (#709). Shared so
/// every adapter draws the line in one place.
String? nonEmptyString(Object? wire) =>
    wire is String && wire.isNotEmpty ? wire : null;
