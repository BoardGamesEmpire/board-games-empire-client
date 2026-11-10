/// How a list screen lays its rows out (#710): a dense list, or a grid of
/// cover thumbnails.
///
/// Stored by `Enum.name`; a name this client doesn't know reads as no
/// choice, so the screen falls back to its default.
enum ListLayout { list, thumbnails }

/// The screens that remember a [ListLayout] of their own (#710).
///
/// Games and Collection are separate screens with separate habits, so a
/// choice made on one does not move the other. Stored by `Enum.name`.
enum ListLayoutScreen { games, collection }
