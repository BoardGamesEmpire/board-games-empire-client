/// Whether a path could match both [a] and [b] as suffixes: one ends with
/// the other, and they differ.
///
/// The ambiguity rule `RoutingAdapter` and `ScriptedServer` both assert.
/// Either resolves such a pair by order, which would answer the wrong route
/// with no warning. Kept here so the two cannot drift.
bool suffixesOverlap(String a, String b) =>
    a != b && (a.endsWith(b) || b.endsWith(a));
