import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';

/// The words for [state], drawn in a badge and spoken in a label in the same
/// place wherever the collection shows one: a row, a cover, and a copy in the
/// picker (#47, #960).
///
/// One switch for all of them, so a state added to the enum is worded in one
/// place and every surface says the same.
String syncLabel(GameCollectionLocalizations l10n, BgeSyncState state) =>
    switch (state) {
      BgeSyncState.waiting => l10n.collectionNotSynced,
      BgeSyncState.stuck => l10n.collectionCouldNotSync,
    };

/// Whether [entry] holds a change the server hasn't had: it was added here
/// and never sent, or changed since its last sync (#47).
///
/// The `unsynced` a row, a cover and a copy in the picker hand
/// `BgeSyncStatusScope.stateOf`, from the one rule, so a copy says in the
/// picker what its row says in the list (#960).
bool hasUnsyncedChange(GameCollection entry) =>
    entry.isLocalOnly || entry.isDirty;
