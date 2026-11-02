import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

import 'add_to_collection_bloc.dart';
import 'add_to_collection_event.dart';
import 'add_to_collection_state.dart';

/// Opens the add sheet over [context] for [game] on [platformGame] (#45).
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
/// SnackBar shows once it settles, so a dismissed add is never silent.
///
/// [repository] and [sender] must be the active session's. The caller
/// resolves them per use: one held across a session change is disposed, and
/// throws. The add is sent through [sender] at once.
Future<AddToCollectionSync?> showAddToCollectionSheet(
  BuildContext context, {
  required GameCollectionRepository repository,
  required SyncOperationSender sender,
  required Game game,
  required PlatformGame platformGame,
}) async {
  // Captured now: the sheet's own context is gone by the time the add
  // settles.
  final messenger = ScaffoldMessenger.of(context);
  final l10n = GameCollectionLocalizations.of(context);
  // Held here rather than by the sheet, so an add still running when the
  // sheet is dismissed settles and says so.
  final bloc = AddToCollectionBloc(
    repository: repository,
    sender: sender,
    platformGameId: platformGame.id,
  );
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => BlocProvider<AddToCollectionBloc>.value(
        value: bloc,
        child: _AddToCollectionSheet(game: game, platformGame: platformGame),
      ),
    );
    final settled = bloc.state.status == AddToCollectionStatus.submitting
        ? await bloc.stream.firstWhere(
            (state) => state.status != AddToCollectionStatus.submitting,
          )
        : bloc.state;
    final sync = settled.status == AddToCollectionStatus.added
        ? settled.sync
        : null;
    if (sync != null && messenger.mounted) {
      final title = game.title;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (sync) {
            AddToCollectionSync.queued => l10n.addToCollectionQueued(title),
            AddToCollectionSync.refused => l10n.addToCollectionRefused(title),
            AddToCollectionSync.synced => l10n.addToCollectionAdded(title),
          }),
        ),
      );
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
/// Physical or digital, required. Copies, from 1. An optional rating from 1
/// to 10, with "No rating" as a choice of its own, and an optional comment
/// (#45). A rating left at "No rating" and a comment left blank are sent as
/// none, so an entry removed and added again keeps its old ones.
///
/// ## What is already there
///
/// Once a medium is chosen, a note under it says how many copies of this
/// platform game on that medium are already in the collection, and what the
/// add makes: an add on a medium already owned raises its quantity. It is a
/// live region, so a screen reader hears it change. An entry removed earlier
/// gets no note.
///
/// ## Copies
///
/// A whole number from 1, typed or stepped with the minus and plus buttons
/// either side of the field. Minus stops at 1, since the server takes only a
/// positive quantity. The only upper bound is storage, not product: the
/// server keeps the quantity in a Postgres `Int`, so the copies already there
/// and the copies added together can't pass 2147483647, and plus stops there.
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
  const _AddToCollectionSheet({required this.game, required this.platformGame});

  final Game game;
  final PlatformGame platformGame;

  @override
  State<_AddToCollectionSheet> createState() => _AddToCollectionSheetState();
}

class _AddToCollectionSheetState extends State<_AddToCollectionSheet> {
  /// The largest quantity the server's column holds: Postgres `Int`.
  static const int _storedMax = 2147483647;

  static const String _medium = 'medium';
  static const String _quantity = 'quantity';
  static const String _rating = 'rating';
  static const String _comment = 'comment';

  static const String _quantityInvalid = 'quantityInvalid';
  static const String _quantityTooMany = 'quantityTooMany';

  /// The copies already in the collection on the medium chosen, which the
  /// quantity's bound counts.
  int _existing = 0;

  late final FormGroup _form = FormGroup({
    _medium: FormControl<GameMedium>(validators: [Validators.required]),
    _quantity: FormControl<String>(
      value: '1',
      validators: [Validators.delegate(_validateQuantity)],
    ),
    _rating: FormControl<int>(),
    _comment: FormControl<String>(),
  });

  final List<StreamSubscription<Object?>> _subscriptions = [];

  AddToCollectionBloc get _bloc => context.read<AddToCollectionBloc>();

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        _form.control(_medium).valueChanges.listen((medium) {
          if (mounted && medium is GameMedium) {
            _bloc.add(AddToCollectionMediumChanged(medium));
          }
        }),
      )
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

  /// What was typed, read as copies to add: a whole number from 1, or null.
  static int? _parseQuantity(Object? typed) {
    final copies = typed is String ? int.tryParse(typed.trim()) : null;
    return copies != null && copies >= 1 ? copies : null;
  }

  Map<String, dynamic>? _validateQuantity(AbstractControl<dynamic> control) {
    final adding = _parseQuantity(control.value);
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
        medium: _form.control(_medium).value! as GameMedium,
        quantity: _parseQuantity(_form.control(_quantity).value)!,
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
        BlocListener<AddToCollectionBloc, AddToCollectionState>(
          listenWhen: (previous, current) =>
              previous.status != current.status &&
              current.status == AddToCollectionStatus.added,
          listener: (context, _) => Navigator.of(context).pop(),
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

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.addToCollectionTitle(
                widget.game.title,
                widget.platformGame.platformName,
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const BgeGap.md(),
          BgeDropdownField<GameMedium>(
            key: AddToCollectionSheet.mediumKey,
            formControlName: _medium,
            label: l10n.addToCollectionMediumLabel,
            hint: l10n.addToCollectionMediumHint,
            readOnly: busy,
            items: [
              for (final medium in GameMedium.values)
                BgeDropdownItem(
                  value: medium,
                  label: switch (medium) {
                    GameMedium.physical => l10n.collectionListMediumPhysical,
                    GameMedium.digital => l10n.collectionListMediumDigital,
                  },
                ),
            ],
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.addToCollectionMediumRequired,
            },
          ),
          if (existing != null) ...[
            const BgeGap.sm(),
            _ExistingNote(existing: existing, parse: _parseQuantity),
          ],
          const BgeGap.md(),
          _QuantityStepper(
            l10n: l10n,
            busy: busy,
            parse: _parseQuantity,
            existing: _existing,
            field: BgeTextField(
              key: AddToCollectionSheet.quantityKey,
              formControlName: _quantity,
              label: l10n.addToCollectionQuantityLabel,
              keyboardType: TextInputType.number,
              readOnly: busy,
              validationMessages: {
                _quantityInvalid: (_) => l10n.addToCollectionQuantityInvalid,
                _quantityTooMany: (_) => l10n.addToCollectionQuantityTooMany,
              },
            ),
          ),
          const BgeGap.md(),
          BgeDropdownField<int?>(
            key: AddToCollectionSheet.ratingKey,
            formControlName: _rating,
            label: l10n.addToCollectionRatingLabel,
            readOnly: busy,
            items: [
              BgeDropdownItem(
                value: null,
                label: l10n.addToCollectionRatingNone,
              ),
              for (var rating = 1; rating <= 10; rating++)
                BgeDropdownItem(
                  value: rating,
                  label: l10n.addToCollectionRatingValue(rating),
                ),
            ],
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
  const _ExistingNote({required this.existing, required this.parse});

  final GameCollection existing;

  /// Reads the copies typed, as the form's validator does.
  final int? Function(Object? typed) parse;

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
        final adding = parse(control.value);
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

/// The copies field between a minus and a plus button.
///
/// Reads the copies from the form, so a step starts from what was typed. A
/// value that isn't a whole number from 1 can't be stepped down, and steps up
/// to 1.
class _QuantityStepper extends StatefulWidget {
  const _QuantityStepper({
    required this.l10n,
    required this.busy,
    required this.parse,
    required this.existing,
    required this.field,
  });

  final GameCollectionLocalizations l10n;

  /// Whether an add is under way, when neither button steps.
  final bool busy;

  /// Reads the copies typed, as the form's validator does.
  final int? Function(Object? typed) parse;

  /// The copies already there on the medium chosen, which plus can't take
  /// the total past what is stored.
  final int existing;

  final Widget field;

  @override
  State<_QuantityStepper> createState() => _QuantityStepperState();
}

class _QuantityStepperState extends State<_QuantityStepper> {
  /// The copies the last step left in the field, which the live region says
  /// while the field still holds them.
  int? _stepped;

  void _step(AbstractControl<String> control, int copies) {
    control
      ..value = '$copies'
      ..markAsTouched();
    setState(() => _stepped = copies);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;

    return ReactiveValueListenableBuilder<String>(
      formControlName: _AddToCollectionSheetState._quantity,
      builder: (context, control, _) {
        final copies = widget.parse(control.value);
        final stepped = copies != null && copies == _stepped ? copies : null;
        final max = _AddToCollectionSheetState._storedMax - widget.existing;
        final canDecrease = !widget.busy && copies != null && copies > 1;
        // A value that isn't a number steps to 1, which must fit too.
        final canIncrease =
            !widget.busy && (copies == null ? max >= 1 : copies < max);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StepButton(
              key: AddToCollectionSheet.quantityDecreaseKey,
              icon: Icons.remove,
              label: l10n.addToCollectionQuantityDecrease,
              onStep: canDecrease ? () => _step(control, copies - 1) : null,
            ),
            Expanded(child: widget.field),
            _StepButton(
              key: AddToCollectionSheet.quantityIncreaseKey,
              icon: Icons.add,
              label: l10n.addToCollectionQuantityIncrease,
              onStep: canIncrease
                  ? () => _step(control, copies == null ? 1 : copies + 1)
                  : null,
            ),
            if (stepped != null)
              _SteppedAnnouncement(
                message: l10n.addToCollectionQuantityStepped(stepped),
              ),
          ],
        );
      },
    );
  }
}

/// A minus or plus button, at least a tap target square.
///
/// At its limit, [onStep] is null and the button stays enabled but does
/// nothing: a disabled button gives up the focus, so stepping down to 1
/// would drop it. Its look and its semantics say it is disabled. The node is
/// named in its label, not by the tooltip, which iOS doesn't read as a name.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.label,
    required this.onStep,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onStep;

  static void _ignore() {}

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final onStep = this.onStep;

    return Semantics(
      container: true,
      button: true,
      enabled: onStep != null,
      label: label,
      onTap: onStep,
      excludeSemantics: true,
      child: SizedBox(
        width: tokens.minTapTarget,
        height: tokens.minTapTarget,
        child: IconButton(
          icon: Icon(icon),
          tooltip: label,
          color: onStep == null ? Theme.of(context).disabledColor : null,
          onPressed: onStep ?? _ignore,
        ),
      ),
    );
  }
}

/// Says the copies a step left in the field to a screen reader, and shows
/// nothing.
class _SteppedAnnouncement extends StatelessWidget {
  const _SteppedAnnouncement({required this.message});

  /// The smallest box whose semantics node survives: an empty rect's can be
  /// dropped. Not a spacing decision.
  static const double _anchorExtent = 1;

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: message,
    child: const SizedBox(width: _anchorExtent, height: _anchorExtent),
  );
}
