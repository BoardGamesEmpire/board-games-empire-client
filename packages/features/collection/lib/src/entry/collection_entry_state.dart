import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../sync/collection_sync.dart';

/// What the screen knows about the entry itself.
enum CollectionEntryView {
  /// The watch hasn't answered yet.
  loading,

  /// The entry is live and [CollectionEntryState.item] is it.
  ready,

  /// The entry is absent: removed elsewhere, or never there. The last
  /// [CollectionEntryState.item] is kept to show what was lost.
  gone,

  /// The watch failed. The last item is kept; a later row clears this.
  error,
}

/// What the entry's edit or removal is doing.
enum CollectionEntryAction {
  /// Nothing under way.
  idle,

  /// An edit is being written and sent. Another edit or a remove is ignored
  /// meanwhile.
  saving,

  /// The edit is in the entry. See [CollectionEntryState.changed] and
  /// [CollectionEntryState.sync].
  saved,

  /// The edit wasn't written.
  saveFailed,

  /// The removal is being written and sent.
  removing,

  /// The entry is removed. See [CollectionEntryState.sync].
  removed,

  /// The removal wasn't written.
  removeFailed,
}

/// What the collection entry screen is showing (#46).
final class CollectionEntryState extends Equatable {
  const CollectionEntryState({
    this.view = CollectionEntryView.loading,
    this.item,
    this.action = CollectionEntryAction.idle,
    this.sync,
    this.changed = true,
  });

  final CollectionEntryView view;

  /// The last live row, kept when [view] is gone or error.
  final GameCollectionListItem? item;

  final CollectionEntryAction action;

  /// What became of the send, set with [CollectionEntryAction.saved] and
  /// [CollectionEntryAction.removed] after a send, and null otherwise.
  final CollectionSync? sync;

  /// False on a [CollectionEntryAction.saved] that made no call because
  /// nothing differed.
  final bool changed;

  /// This state with a new view, and a new item if one is given, keeping the
  /// action.
  CollectionEntryState withView(
    CollectionEntryView view, {
    GameCollectionListItem? item,
  }) => CollectionEntryState(
    view: view,
    item: item ?? this.item,
    action: action,
    sync: sync,
    changed: changed,
  );

  /// This state at [action], keeping the view and item. [sync] and [changed]
  /// go with the action and are not carried over.
  CollectionEntryState withAction(
    CollectionEntryAction action, {
    CollectionSync? sync,
    bool changed = true,
  }) => CollectionEntryState(
    view: view,
    item: item,
    action: action,
    sync: sync,
    changed: changed,
  );

  @override
  List<Object?> get props => [view, item, action, sync, changed];
}
