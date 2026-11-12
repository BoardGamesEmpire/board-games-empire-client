import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/entry/collection_entry_bloc.dart';
import 'package:game_collection/src/entry/collection_entry_event.dart';
import 'package:game_collection/src/entry/collection_entry_state.dart';
import 'package:game_collection/src/form/collection_quantity_field.dart';
import 'package:game_collection/src/form/collection_rating_field.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens the edit sheet over [context] for the entry [bloc] shows (#46).
///
/// The sheet starts from the entry as it is when this is called, and never
/// takes the values of a later row: what the user is typing isn't replaced
/// under them. Nothing opens when [bloc] has no item yet, since the detail
/// offers the edit only once it is ready.
///
/// The sheet closes itself when the save lands. [bloc] belongs to the caller,
/// who closes it; the screen beneath says what became of the save, since the
/// sheet can be dismissed while it is under way.
Future<void> showEditCollectionEntrySheet(
  BuildContext context, {
  required CollectionEntryBloc bloc,
}) async {
  if (bloc.state.item == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider<CollectionEntryBloc>.value(
      value: bloc,
      child: const _EditCollectionEntrySheet(),
    ),
  );
}

/// The edit sheet's finder keys.
///
/// ## What the sheet asks
///
/// The entry's five editable fields (#46): copies, rating, comment, favorite
/// and would-play-again. Plays and the last played date aren't edited here.
/// The sheet sends the form's whole state with the entry it opened on, and
/// the bloc works out what changed against that entry, so a save with
/// nothing changed makes no call and closes. A row changed elsewhere while
/// the sheet is open doesn't make an untouched field look changed, and isn't
/// written over.
///
/// While a save is under way the fields are read-only, the switches too,
/// never disabled: each keeps its place in the focus order and its value.
/// The in-flight signal is the submit button's.
///
/// ## What can't be undone
///
/// A rating can't be cleared (#679), so an entry that has one offers 1 to 10
/// only, and starts at its rating. An entry without one starts at, and offers,
/// "No rating". For the same reason a comment that was set can't be emptied:
/// the field says so rather than sending a blank the server would ignore.
///
/// ## Copies
///
/// As on the add sheet: a whole number from 1, typed or stepped, whose upper
/// bound is storage, [GameCollectionRepository.maxQuantity].
///
/// ## A failed save
///
/// The sheet stays open with what was entered and a banner above the button,
/// which the next edit retires. A failure from an earlier sheet isn't shown:
/// only this sheet's own submit. When the entry was removed while the sheet
/// was open (the bloc's view is gone), the banner says so rather than to try
/// again.
///
/// ## A leftover outcome
///
/// On opening, a `saved` or `saveFailed` the bloc still holds (an outcome
/// nobody cleared) is cleared once. Otherwise a no-change save, which emits
/// `saved` with no `saving` before it, would equal the leftover state and
/// never reach the sheet's listener. The sheet adds no other clear: the screen
/// clears the outcome it reports.
///
/// ## The keyboard
///
/// The sheet pads its scroll view by the keyboard's height, which a modal
/// bottom sheet doesn't make room for, so the field being typed in stays in
/// view.
abstract final class EditCollectionEntrySheet {
  static const Key sheetKey = Key('collection_edit.sheet');
  static const Key quantityKey = Key('collection_edit.quantity');
  static const Key quantityDecreaseKey = Key(
    'collection_edit.quantity.decrease',
  );
  static const Key quantityIncreaseKey = Key(
    'collection_edit.quantity.increase',
  );
  static const Key ratingKey = Key('collection_edit.rating');
  static const Key commentKey = Key('collection_edit.comment');
  static const Key favoriteKey = Key('collection_edit.favorite');
  static const Key playAgainKey = Key('collection_edit.play_again');
  static const Key submitKey = Key('collection_edit.submit');
}

class _EditCollectionEntrySheet extends StatefulWidget {
  const _EditCollectionEntrySheet();

  @override
  State<_EditCollectionEntrySheet> createState() =>
      _EditCollectionEntrySheetState();
}

class _EditCollectionEntrySheetState extends State<_EditCollectionEntrySheet> {
  static const int _storedMax = GameCollectionRepository.maxQuantity;

  static const String _quantity = 'quantity';
  static const String _rating = 'rating';
  static const String _comment = 'comment';
  static const String _favorite = 'favorite';
  static const String _playAgain = 'playAgain';

  static const String _quantityInvalid = 'quantityInvalid';
  static const String _quantityTooMany = 'quantityTooMany';
  static const String _commentCantClear = 'commentCantClear';

  /// The entry the sheet opened on, which the form starts from, the comment's
  /// check reads, and the submit sends as the edit's base.
  late final GameCollection _opened = context
      .read<CollectionEntryBloc>()
      .state
      .item!
      .entry;

  /// The title of the game the entry is of.
  late final String _title = context
      .read<CollectionEntryBloc>()
      .state
      .item!
      .title;

  late final FormGroup _form = FormGroup({
    _quantity: FormControl<String>(
      value: '${_opened.quantity}',
      validators: [Validators.delegate(_validateQuantity)],
    ),
    _rating: FormControl<int>(value: _opened.rating),
    _comment: FormControl<String>(
      value: _opened.comment,
      validators: [Validators.delegate(_validateComment)],
    ),
    _favorite: FormControl<bool>(value: _opened.favorite ?? false),
    _playAgain: FormControl<bool>(value: _opened.playAgain ?? false),
  });

  /// Whether this sheet has submitted since it opened or since the form was
  /// last edited. A save failure is shown only then: one the bloc still holds
  /// from an earlier sheet isn't about this one.
  bool _submitted = false;

  StreamSubscription<Object?>? _subscription;

  CollectionEntryBloc get _bloc => context.read<CollectionEntryBloc>();

  @override
  void initState() {
    super.initState();
    final action = _bloc.state.action;
    if (action == CollectionEntryAction.saved ||
        action == CollectionEntryAction.saveFailed) {
      _bloc.add(const CollectionEntryActionCleared());
    }
    _subscription = _form.valueChanges.listen((_) {
      if (mounted && _submitted) setState(() => _submitted = false);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _form.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _validateQuantity(AbstractControl<dynamic> control) {
    final copies = CollectionQuantityField.parseCopies(control.value);
    if (copies == null) return {_quantityInvalid: true};
    if (copies > _storedMax) return {_quantityTooMany: true};
    return null;
  }

  /// A comment that was set can't be emptied (#679): a blank is "unchanged"
  /// to the server, so it would look saved and not be.
  Map<String, dynamic>? _validateComment(AbstractControl<dynamic> control) {
    final typed = control.value;
    final hadComment = _opened.comment?.trim().isNotEmpty ?? false;
    final blank = typed is! String || typed.trim().isEmpty;
    return hadComment && blank ? {_commentCantClear: true} : null;
  }

  bool get _busy {
    final action = _bloc.state.action;
    return action == CollectionEntryAction.saving ||
        (action == CollectionEntryAction.saved && _submitted);
  }

  void _submit() {
    if (_busy) return;
    if (!_form.valid) return _form.rejectSubmit();

    setState(() => _submitted = true);
    _bloc.add(
      CollectionEntryEditSubmitted(
        base: _opened,
        quantity: CollectionQuantityField.parseCopies(
          _form.control(_quantity).value,
        )!,
        rating: _form.control(_rating).value as int?,
        comment: _form.control(_comment).value as String?,
        favorite: _form.control(_favorite).value! as bool,
        playAgain: _form.control(_playAgain).value! as bool,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);

    // A sheet dismissed during the save stays mounted through its exit, and
    // pop takes whichever route is on top, so a sheet that is no longer
    // current would pop the screen beneath it.
    return BlocListener<CollectionEntryBloc, CollectionEntryState>(
      listenWhen: (previous, current) =>
          previous.action != current.action &&
          current.action == CollectionEntryAction.saved,
      listener: (context, _) {
        if (ModalRoute.isCurrentOf(context) ?? true) {
          Navigator.of(context).pop();
        }
      },
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          key: EditCollectionEntrySheet.sheetKey,
          padding: EdgeInsets.only(
            left: tokens.spaceMd,
            right: tokens.spaceMd,
            bottom: tokens.spaceLg,
          ),
          child: BlocBuilder<CollectionEntryBloc, CollectionEntryState>(
            buildWhen: (previous, current) => previous.action != current.action,
            builder: _formFor,
          ),
        ),
      ),
    );
  }

  Widget _formFor(BuildContext context, CollectionEntryState state) {
    final l10n = GameCollectionLocalizations.of(context);
    final busy = _busy;

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.editCollectionTitle(_title),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const BgeGap.md(),
          CollectionQuantityField(
            formControlName: _quantity,
            max: _storedMax,
            busy: busy,
            fieldKey: EditCollectionEntrySheet.quantityKey,
            decreaseKey: EditCollectionEntrySheet.quantityDecreaseKey,
            increaseKey: EditCollectionEntrySheet.quantityIncreaseKey,
            label: l10n.addToCollectionQuantityLabel,
            validationMessages: {
              _quantityInvalid: (_) => l10n.addToCollectionQuantityInvalid,
              _quantityTooMany: (_) => l10n.addToCollectionQuantityTooMany,
            },
          ),
          const BgeGap.md(),
          CollectionRatingField(
            formControlName: _rating,
            fieldKey: EditCollectionEntrySheet.ratingKey,
            busy: busy,
            offerNone: _opened.rating == null,
          ),
          const BgeGap.md(),
          BgeTextField(
            key: EditCollectionEntrySheet.commentKey,
            formControlName: _comment,
            label: l10n.addToCollectionCommentLabel,
            readOnly: busy,
            textInputAction: TextInputAction.done,
            minLines: 1,
            maxLines: 4,
            onSubmitted: _submit,
            validationMessages: {
              _commentCantClear: (_) => l10n.editCollectionCommentCantClear,
            },
          ),
          const BgeGap.sm(),
          BgeSwitchField(
            switchKey: EditCollectionEntrySheet.favoriteKey,
            formControlName: _favorite,
            label: l10n.editCollectionFavorite,
            readOnly: busy,
          ),
          BgeSwitchField(
            switchKey: EditCollectionEntrySheet.playAgainKey,
            formControlName: _playAgain,
            label: l10n.editCollectionPlayAgain,
            readOnly: busy,
          ),
          const BgeGap.lg(),
          BgeFormActions(
            failure:
                state.action == CollectionEntryAction.saveFailed && _submitted
                ? BgeFormFailure(
                    title: l10n.editCollectionFailedTitle,
                    message: state.view == CollectionEntryView.gone
                        ? l10n.editCollectionFailedGoneBody
                        : l10n.editCollectionFailedBody,
                  )
                : null,
            action: BgeSubmitButton(
              key: EditCollectionEntrySheet.submitKey,
              label: l10n.editCollectionSubmit,
              progressLabel: l10n.editCollectionInProgress,
              submitting: busy,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}
