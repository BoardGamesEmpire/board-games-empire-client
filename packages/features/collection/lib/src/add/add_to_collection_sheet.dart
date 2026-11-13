import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/add/add_to_collection_bloc.dart';
import 'package:game_collection/src/add/add_to_collection_event.dart';
import 'package:game_collection/src/add/add_to_collection_state.dart';
import 'package:game_collection/src/add/starting_medium.dart';
import 'package:game_collection/src/form/collection_quantity_field.dart';
import 'package:game_collection/src/form/collection_rating_field.dart';
import 'package:game_collection/src/medium_label.dart';
import 'package:game_collection/src/sync/collection_sync.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens the add sheet over [context] for [game] (#45), offering the
/// platforms in [options] and, on each, only the mediums still free (#708).
///
/// [options] is the caller's snapshot of what the user owns at the press, and
/// must not be empty: the sheet lists it as it was then, because a dropdown
/// whose items change under a chosen value shows its hint while the form keeps
/// the value. [platformGameId] chooses one of them, as a platform's own add
/// does. Without it, a lone option is chosen, and among several the user
/// picks.
///
/// Resolves to what became of the add's send, or null when the sheet closed
/// without an add. On an add the sheet closes, and a SnackBar on [context]'s
/// `ScaffoldMessenger` says what happened, so the screen beneath says so.
/// It resolves to the outcome rather than the entry: a send the server
/// confirms moves the entry to the server's id, so the one written here is
/// gone by then.
///
/// The sheet can be dismissed while an add is under way, and the send can
/// take as long as the network's connect timeout. The add goes on, and its
/// SnackBar shows once it settles, so a dismissed add is never silent: one
/// whose write fails after the sheet is gone says it wasn't added. A failure
/// the sheet already showed gets no SnackBar.
///
/// [repository] and [sender] must be the active session's. The caller
/// resolves them per use: one held across a session change is disposed, and
/// throws. The add is sent through [sender] at once.
Future<CollectionSync?> showAddToCollectionSheet(
  BuildContext context, {
  required GameCollectionRepository repository,
  required SyncOperationSender sender,
  required Game game,
  required List<CollectionAddOption> options,
  String? platformGameId,
}) async {
  assert(options.isNotEmpty, 'The sheet needs a platform to offer.');
  assert(
    options.every((option) => option.freeMediums.isNotEmpty),
    "An option's free mediums are never empty: a platform owned in every "
    'medium is left out.',
  );
  assert(
    platformGameId == null ||
        options.any((option) => option.platformGame.id == platformGameId),
    'The platform chosen must be one the sheet offers.',
  );
  // Captured now: the sheet's own context is gone by the time the add
  // settles.
  final messenger = ScaffoldMessenger.of(context);
  final l10n = GameCollectionLocalizations.of(context);
  // Held here rather than by the sheet, so an add still running when the
  // sheet is dismissed settles and says so.
  final bloc = AddToCollectionBloc(repository: repository, sender: sender);
  try {
    await showModalBottomSheet<void>(
      context: context,
      // Over the navigation shell's bar or rail too, not only the page (#414).
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => BlocProvider<AddToCollectionBloc>.value(
        value: bloc,
        child: _AddToCollectionSheet(
          game: game,
          options: options,
          platformGameId: platformGameId,
        ),
      ),
    );
    final dismissedMidAdd =
        bloc.state.status == AddToCollectionStatus.submitting;
    final settled = dismissedMidAdd
        ? await bloc.stream.firstWhere(
            (state) => state.status != AddToCollectionStatus.submitting,
          )
        : bloc.state;
    final sync = settled.status == AddToCollectionStatus.added
        ? settled.sync
        : null;
    final title = game.title;
    // A failure the sheet showed was seen before it was dismissed. One that
    // came after has no banner left to show it, so it is said here.
    final message = switch (sync) {
      CollectionSync.queued => l10n.addToCollectionQueued(title),
      CollectionSync.refused => l10n.addToCollectionRefused(title),
      CollectionSync.synced => l10n.addToCollectionAdded(title),
      null when dismissedMidAdd => l10n.addToCollectionDismissedFailed(title),
      null => null,
    };
    if (message != null && messenger.mounted) {
      messenger.replaceSnackBar(message);
    }
    return sync;
  } finally {
    // Not awaited, as a BlocProvider doesn't await it: the outcome is
    // known, and nothing waits on the close.
    unawaited(bloc.close());
  }
}

/// The add sheet's finder keys.
///
/// ## What the sheet asks
///
/// The platform, required: the platforms the caller offers, each with a
/// medium still free (#708). One offered alone, or one the caller names, is
/// chosen already.
///
/// The medium, required, offering only the mediums free on the platform
/// chosen. It waits, read-only, for a platform. Each platform starts it
/// where [startingMedium] says, and a new platform starts it again, unless
/// the user picked the medium and the new platform has it free too. A
/// medium the new platform has no room for is never kept, since the field
/// would show its hint while the form kept the value.
///
/// Copies, from 1. An optional rating from 1 to 10, with "No rating" as a
/// choice of its own, and an optional comment (#45). A rating left at "No
/// rating" and a comment left blank are sent as none, so an entry removed
/// and added again keeps its old ones.
///
/// ## What is already there
///
/// Once a medium is chosen, a note under it says how many copies of the
/// platform game on that medium are already in the collection, and what the
/// add makes: an add on a medium already owned raises its quantity. The
/// sheet offers only the mediums free when it opened, so the note is for an
/// entry added since. It is a live region, so a screen reader hears it
/// change. An entry removed earlier gets no note.
///
/// ## Copies
///
/// A whole number from 1, typed or stepped with the minus and plus buttons
/// either side of the field. Minus stops at 1, since the server takes only a
/// positive quantity. The only upper bound is storage, not product: the
/// server keeps the quantity in a Postgres `Int`, so the copies already there
/// and the copies added together can't pass 2147483647, and plus stops there.
/// The form counts the copies from the medium's lookup, which a quick submit
/// can beat; the repository checks the total against the entry as stored,
/// and an add past it fails as any failed add does.
///
/// A button at its limit stays enabled and does nothing, so one pressed down
/// to its limit keeps the focus. Its semantics say it is disabled. After a
/// step a hidden live region says the copies now in the field, since the
/// field itself isn't focused to be read.
///
/// ## The keyboard
///
/// The sheet pads its scroll view by the keyboard's height, which a modal
/// bottom sheet doesn't make room for, so the field being typed in stays in
/// view.
abstract final class AddToCollectionSheet {
  static const Key sheetKey = Key('collection_add.sheet');
  static const Key platformKey = Key('collection_add.platform');
  static const Key mediumKey = Key('collection_add.medium');
  static const Key quantityKey = Key('collection_add.quantity');
  static const Key quantityDecreaseKey = Key(
    'collection_add.quantity.decrease',
  );
  static const Key quantityIncreaseKey = Key(
    'collection_add.quantity.increase',
  );
  static const Key ratingKey = Key('collection_add.rating');
  static const Key commentKey = Key('collection_add.comment');
  static const Key existingKey = Key('collection_add.existing');
  static const Key submitKey = Key('collection_add.submit');
}

class _AddToCollectionSheet extends StatefulWidget {
  const _AddToCollectionSheet({
    required this.game,
    required this.options,
    required this.platformGameId,
  });

  final Game game;
  final List<CollectionAddOption> options;
  final String? platformGameId;

  @override
  State<_AddToCollectionSheet> createState() => _AddToCollectionSheetState();
}

class _AddToCollectionSheetState extends State<_AddToCollectionSheet> {
  /// The largest quantity the server's column holds, which the repository
  /// enforces too.
  static const int _storedMax = GameCollectionRepository.maxQuantity;

  static const String _platform = 'platform';
  static const String _medium = 'medium';
  static const String _quantity = 'quantity';
  static const String _rating = 'rating';
  static const String _comment = 'comment';

  static const String _quantityInvalid = 'quantityInvalid';
  static const String _quantityTooMany = 'quantityTooMany';

  /// The copies already in the collection on the medium chosen, which the
  /// quantity's bound counts.
  int _existing = 0;

  /// The option chosen, or null until one is. Set with the medium it starts,
  /// so the medium field is never built with one option's items and the
  /// other's value.
  CollectionAddOption? _option;

  /// Whether the medium in the form is one the user picked, which a new
  /// platform keeps if it has it free. The sheet sets the medium itself
  /// without an event, so every change the medium control reports is a pick:
  /// a flag set around the sheet's own change would be cleared before its
  /// event arrived, since the control reports changes asynchronously.
  bool _userPickedMedium = false;

  late final FormGroup _form;

  final List<StreamSubscription<Object?>> _subscriptions = [];

  AddToCollectionBloc get _bloc => context.read<AddToCollectionBloc>();

  FormControl<String> get _platformControl =>
      _form.control(_platform) as FormControl<String>;

  FormControl<GameMedium> get _mediumControl =>
      _form.control(_medium) as FormControl<GameMedium>;

  @override
  void initState() {
    super.initState();
    final chosen =
        widget.platformGameId ??
        (widget.options.length == 1
            ? widget.options.single.platformGame.id
            : null);
    final option = chosen == null ? null : _optionFor(chosen);
    final medium = option == null ? null : _startFor(option);
    _option = option;
    _form = FormGroup({
      _platform: FormControl<String>(
        value: option?.platformGame.id,
        validators: [Validators.required],
      ),
      _medium: FormControl<GameMedium>(
        value: medium,
        validators: [Validators.required],
      ),
      _quantity: FormControl<String>(
        value: '1',
        validators: [Validators.delegate(_validateQuantity)],
      ),
      _rating: FormControl<int>(),
      _comment: FormControl<String>(),
    });
    if (option != null) {
      // So a start already owned, since the caller looked, gets its note.
      _bloc.add(
        AddToCollectionChoiceChanged(
          platformGameId: option.platformGame.id,
          medium: medium,
        ),
      );
    }

    _subscriptions
      ..add(_platformControl.valueChanges.listen(_onPlatformPicked))
      ..add(_mediumControl.valueChanges.listen(_onMediumPicked))
      // Every change, the bloc keeping only the one that retires a failure,
      // as `CreateHouseholdForm` does.
      ..add(
        _form.valueChanges.listen((_) {
          if (mounted) _bloc.add(const AddToCollectionFailureCleared());
        }),
      );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _form.dispose();
    super.dispose();
  }

  CollectionAddOption? _optionFor(String platformGameId) => widget.options
      .where((option) => option.platformGame.id == platformGameId)
      .firstOrNull;

  GameMedium? _startFor(CollectionAddOption option) =>
      startingMedium(option.platformGame.platformType, option.freeMediums);

  /// Starts the medium for the platform picked, unless the user picked the
  /// medium and the new platform has it free.
  void _onPlatformPicked(String? platformGameId) {
    if (!mounted || platformGameId == null) return;
    final option = _optionFor(platformGameId);
    if (option == null) return;

    final current = _mediumControl.value;
    final keep =
        _userPickedMedium &&
        current != null &&
        option.freeMediums.contains(current);
    final medium = keep ? current : _startFor(option);
    // A medium the sheet replaced is no longer the user's.
    _userPickedMedium = keep;
    // No event: only the user's picks are reported, see [_userPickedMedium].
    _mediumControl.updateValue(medium, emitEvent: false);
    setState(() => _option = option);
    _bloc.add(
      AddToCollectionChoiceChanged(
        platformGameId: platformGameId,
        medium: medium,
      ),
    );
  }

  void _onMediumPicked(GameMedium? medium) {
    if (!mounted || medium == null) return;
    _userPickedMedium = true;
    final option = _option;
    if (option == null) return;
    _bloc.add(
      AddToCollectionChoiceChanged(
        platformGameId: option.platformGame.id,
        medium: medium,
      ),
    );
  }

  Map<String, dynamic>? _validateQuantity(AbstractControl<dynamic> control) {
    final adding = CollectionQuantityField.parseCopies(control.value);
    if (adding == null) return {_quantityInvalid: true};
    if (adding > _storedMax - _existing) return {_quantityTooMany: true};
    return null;
  }

  void _submit() {
    final status = _bloc.state.status;
    if (status == AddToCollectionStatus.submitting ||
        status == AddToCollectionStatus.added) {
      return;
    }
    if (!_form.valid) return _form.rejectSubmit();

    final comment = (_form.control(_comment).value as String?)?.trim();
    _bloc.add(
      AddToCollectionSubmitted(
        platformGameId: _platformControl.value!,
        medium: _mediumControl.value!,
        quantity: CollectionQuantityField.parseCopies(
          _form.control(_quantity).value,
        )!,
        rating: _form.control(_rating).value as int?,
        // Blank is none, which keeps an old comment on an entry added again.
        comment: comment == null || comment.isEmpty ? null : comment,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return MultiBlocListener(
      listeners: [
        BlocListener<AddToCollectionBloc, AddToCollectionState>(
          listenWhen: (previous, current) =>
              previous.existing != current.existing,
          listener: (context, state) {
            _existing = state.existing?.quantity ?? 0;
            _form.control(_quantity).updateValueAndValidity();
          },
        ),
        // [showAddToCollectionSheet] says what became of the add.
        //
        // A sheet dismissed during the send stays mounted through its exit,
        // and pop takes whichever route is on top, so a sheet that is no
        // longer current would pop the screen beneath it.
        BlocListener<AddToCollectionBloc, AddToCollectionState>(
          listenWhen: (previous, current) =>
              previous.status != current.status &&
              current.status == AddToCollectionStatus.added,
          listener: (context, _) {
            if (ModalRoute.isCurrentOf(context) ?? true) {
              Navigator.of(context).pop();
            }
          },
        ),
      ],
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          key: AddToCollectionSheet.sheetKey,
          padding: EdgeInsets.only(
            left: tokens.spaceMd,
            right: tokens.spaceMd,
            bottom: tokens.spaceLg,
          ),
          child: BlocBuilder<AddToCollectionBloc, AddToCollectionState>(
            builder: (context, state) => _formFor(context, l10n, state),
          ),
        ),
      ),
    );
  }

  Widget _formFor(
    BuildContext context,
    GameCollectionLocalizations l10n,
    AddToCollectionState state,
  ) {
    final busy =
        state.status == AddToCollectionStatus.submitting ||
        state.status == AddToCollectionStatus.added;
    final existing = state.existing;
    final option = _option;

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.addToCollectionTitle(widget.game.title),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const BgeGap.md(),
          BgeDropdownField<String>(
            key: AddToCollectionSheet.platformKey,
            formControlName: _platform,
            label: l10n.addToCollectionPlatformLabel,
            hint: l10n.addToCollectionPlatformHint,
            readOnly: busy,
            items: [
              for (final option in widget.options)
                BgeDropdownItem(
                  value: option.platformGame.id,
                  label: option.platformGame.platformName,
                ),
            ],
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.addToCollectionPlatformRequired,
            },
          ),
          const BgeGap.md(),
          // A new platform is a new field, built from the medium the sheet
          // set without an event, so a menu open on the old platform's
          // mediums never offers them for the new one.
          KeyedSubtree(
            key: ValueKey<String?>(option?.platformGame.id),
            child: BgeDropdownField<GameMedium>(
              key: AddToCollectionSheet.mediumKey,
              formControlName: _medium,
              label: l10n.addToCollectionMediumLabel,
              hint: l10n.addToCollectionMediumHint,
              // Nothing to offer until a platform is chosen.
              readOnly: busy || option == null,
              items: [
                // In the order the enum gives, whatever the set's.
                for (final medium in GameMedium.values)
                  if (option?.freeMediums.contains(medium) ?? false)
                    BgeDropdownItem(
                      value: medium,
                      label: mediumLabel(l10n, medium),
                    ),
              ],
              validationMessages: {
                ValidationMessage.required: (_) =>
                    l10n.addToCollectionMediumRequired,
              },
            ),
          ),
          if (existing != null) ...[
            const BgeGap.sm(),
            _ExistingNote(existing: existing),
          ],
          const BgeGap.md(),
          CollectionQuantityField(
            formControlName: _quantity,
            max: _storedMax - _existing,
            busy: busy,
            fieldKey: AddToCollectionSheet.quantityKey,
            decreaseKey: AddToCollectionSheet.quantityDecreaseKey,
            increaseKey: AddToCollectionSheet.quantityIncreaseKey,
            label: l10n.addToCollectionQuantityLabel,
            validationMessages: {
              _quantityInvalid: (_) => l10n.addToCollectionQuantityInvalid,
              _quantityTooMany: (_) => l10n.addToCollectionQuantityTooMany,
            },
          ),
          const BgeGap.md(),
          CollectionRatingField(
            formControlName: _rating,
            fieldKey: AddToCollectionSheet.ratingKey,
            busy: busy,
            offerNone: true,
          ),
          const BgeGap.md(),
          BgeTextField(
            key: AddToCollectionSheet.commentKey,
            formControlName: _comment,
            label: l10n.addToCollectionCommentLabel,
            readOnly: busy,
            textInputAction: TextInputAction.done,
            minLines: 1,
            maxLines: 4,
            onSubmitted: _submit,
          ),
          const BgeGap.lg(),
          BgeFormActions(
            failure: state.status == AddToCollectionStatus.failed
                ? BgeFormFailure(
                    title: l10n.addToCollectionFailedTitle,
                    message: l10n.addToCollectionFailedBody,
                  )
                : null,
            action: BgeSubmitButton(
              key: AddToCollectionSheet.submitKey,
              label: l10n.addToCollectionSubmit,
              progressLabel: l10n.addToCollectionInProgress,
              submitting: busy,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// How many copies on the chosen medium are already in the collection, and,
/// while the copies typed are a number, what the add makes.
class _ExistingNote extends StatelessWidget {
  const _ExistingNote({required this.existing});

  final GameCollection existing;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final have = existing.quantity;
    final haveText = switch (existing.medium) {
      GameMedium.physical => l10n.addToCollectionHavePhysical(have),
      GameMedium.digital => l10n.addToCollectionHaveDigital(have),
    };

    return ReactiveValueListenableBuilder<String>(
      formControlName: _AddToCollectionSheetState._quantity,
      builder: (context, control, _) {
        final adding = CollectionQuantityField.parseCopies(control.value);
        // A total past what can be stored is the field's error to say.
        final makes =
            adding == null ||
                adding > _AddToCollectionSheetState._storedMax - have
            ? null
            : l10n.addToCollectionMakes(adding, have + adding);
        // Its own node, so the sentence is announced whole when it changes.
        return Semantics(
          key: AddToCollectionSheet.existingKey,
          container: true,
          liveRegion: true,
          child: Text(makes == null ? haveText : '$haveText $makes'),
        );
      },
    );
  }
}
