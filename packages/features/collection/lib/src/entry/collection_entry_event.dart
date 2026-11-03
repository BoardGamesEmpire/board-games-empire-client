import 'package:hydration/hydration.dart';
import 'package:models/domain.dart';

/// What can happen to the collection entry screen's bloc (#46).
sealed class CollectionEntryEvent {
  const CollectionEntryEvent();
}

/// The edit sheet was submitted. Carries the form's whole state, not a diff,
/// and the entry the sheet opened on, [base]: the bloc works out what changed
/// against [base], not against the row it shows now.
///
/// A null [rating] means none is set, which is unchanged: a rating once set
/// is never cleared (#679). The same goes for a blank [comment].
final class CollectionEntryEditSubmitted extends CollectionEntryEvent {
  const CollectionEntryEditSubmitted({
    required this.base,
    required this.quantity,
    required this.favorite,
    required this.playAgain,
    this.rating,
    this.comment,
  });

  /// The entry the sheet opened on, whose values the form started from.
  ///
  /// The form never takes a later row's values, so a field nobody touched
  /// still holds [base]'s. Compared against the latest row instead, a row
  /// changed elsewhere while the sheet was open would make that field look
  /// changed, and the save would write the old value back over the new one.
  final GameCollection base;

  final int quantity;
  final int? rating;
  final String? comment;
  final bool favorite;
  final bool playAgain;
}

/// The user asked to read the entry again after its watch failed. Watches it
/// anew, loading until the new watch answers; does nothing unless the view is
/// `error`.
final class CollectionEntryRetried extends CollectionEntryEvent {
  const CollectionEntryRetried();
}

/// The user confirmed removing the entry.
final class CollectionEntryRemoveConfirmed extends CollectionEntryEvent {
  const CollectionEntryRemoveConfirmed();
}

/// The screen has shown a failed or finished save or removal and is done with
/// it. Takes `saved`, `saveFailed`, `removeFailed` and `removed` back to
/// `idle`; does nothing while a save or a removal is under way.
///
/// A screen clears `removed` only when it couldn't close on it, because
/// another route covered it. The view is then `gone` once the row is absent,
/// so the screen shows the entry went rather than a live entry with nothing
/// to do, and a later re-add shows it ready again.
final class CollectionEntryActionCleared extends CollectionEntryEvent {
  const CollectionEntryActionCleared();
}

/// The row watch answered. The bloc's own event, so its emits stay inside a
/// handler; not exported.
final class CollectionEntryRowChanged extends CollectionEntryEvent {
  const CollectionEntryRowChanged(this.item);

  /// The live entry, or null when it is absent, removed or another user's.
  final GameCollectionListItem? item;
}

/// The row watch failed. The bloc's own event; not exported.
final class CollectionEntryWatchFailed extends CollectionEntryEvent {
  const CollectionEntryWatchFailed();
}

/// The row watch closed. The bloc's own event; not exported.
final class CollectionEntryWatchEnded extends CollectionEntryEvent {
  const CollectionEntryWatchEnded();
}

/// The collection's hydrate said what it is doing. The bloc's own event; not
/// exported.
final class CollectionEntryHydrationUpdated extends CollectionEntryEvent {
  const CollectionEntryHydrationUpdated(this.hydration);

  final Hydration hydration;
}

/// The collection's hydration status stream closed. The bloc's own event;
/// not exported.
final class CollectionEntryHydrationEnded extends CollectionEntryEvent {
  const CollectionEntryHydrationEnded();
}
