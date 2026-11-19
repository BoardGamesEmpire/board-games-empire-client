import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/create/event_create_parts.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// An event's basics, on the create form (#499) and the edit form (#500):
/// its title, its household where there is a picker, what kind it is and
/// who can see it, then its description, place and link.
///
/// It edits the basics of the ambient [ReactiveForm], whose controls
/// [buildEventBasicsControls] built, and the household's where
/// [offersHouseholds].
///
/// `unknown` is never offered for the type or who can see it: it has no
/// label, and nothing to send. Each menu is an [EventCreateMenu], as the
/// rules' are. While one is empty it shows the server's default where
/// [hintsDefaults], as on the create form, where an untouched one gets
/// that default.
class EventBasicsSection extends StatelessWidget {
  const EventBasicsSection({
    required this.readOnly,
    this.offersHouseholds = false,
    this.offered,
    this.offerVersion = 0,
    this.hintsDefaults = true,
    super.key,
  });

  static const Key titleKey = Key('event_create.title');
  static const Key householdKey = Key('event_create.household');
  static const Key typeKey = Key('event_create.type');
  static const Key reachKey = Key('event_create.reach');

  /// Key on the line under the reach menu saying what *Extended network*
  /// means, shown while it is chosen.
  static const Key reachNoteKey = Key('event_create.reach_note');
  static const Key descriptionKey = Key('event_create.description');
  static const Key locationKey = Key('event_create.location');
  static const Key urlKey = Key('event_create.url');

  /// Whether there is a household picker: false where there are no
  /// households to read, and on the edit form, which can't move an event.
  final bool offersHouseholds;

  /// What the household picker offers besides no household, or null until
  /// the first list arrives.
  final List<Household>? offered;

  /// Changes each time [offered] changes which households it holds.
  final int offerVersion;

  /// Whether a write is on its way: nothing here takes an edit.
  final bool readOnly;

  /// Whether an empty type or reach menu shows the server's default, which
  /// an untouched one gets on create.
  ///
  /// False on the edit form: there an untouched menu keeps what the event
  /// has, and one that is empty holds a value this app doesn't know, which
  /// the default would misname.
  final bool hintsDefaults;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offered = this.offered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EventCreateHeading(l10n.eventCreateBasicsTitle),
        const BgeGap.sm(),
        BgeTextField(
          key: titleKey,
          formControlName: EventCreateControls.title,
          label: l10n.eventCreateName,
          readOnly: readOnly,
          validationMessages: {
            ValidationMessage.required: (_) => l10n.eventCreateNameRequired,
          },
        ),
        if (offersHouseholds) ...[
          const BgeGap.md(),
          // Drawn anew when the households offered change, which closes a
          // menu open on the ones offered before.
          KeyedSubtree(
            key: ValueKey(offerVersion),
            child: EventCreateMenu<String?>(
              key: householdKey,
              formControlName: EventCreateControls.household,
              label: l10n.eventCreateHousehold,
              items: [
                // Its value is null: the event joins no household.
                BgeDropdownItem(
                  value: null,
                  label: l10n.eventCreateNoHousehold,
                ),
                for (final household in offered ?? const <Household>[])
                  BgeDropdownItem(value: household.id, label: household.name),
              ],
              // Nothing to pick until the households answer.
              readOnly: readOnly || offered == null,
            ),
          ),
        ],
        const BgeGap.md(),
        EventCreateMenu<EventType>(
          key: typeKey,
          formControlName: EventCreateControls.type,
          label: l10n.eventCreateType,
          hint: hintsDefaults ? l10n.eventsTypeCasualGathering : null,
          items: eventCreateMenuItems(
            EventType.values,
            (type) => eventTypeLabel(l10n, type),
          ),
          readOnly: readOnly,
        ),
        const BgeGap.md(),
        // From the fewest people to the most: the enum's own order is the
        // backend's alphabetical one, which says nothing about reach.
        EventCreateMenu<Reach>(
          key: reachKey,
          formControlName: EventCreateControls.reach,
          label: l10n.eventCreateReach,
          hint: hintsDefaults ? l10n.eventsReachFriends : null,
          items: eventCreateMenuItems(
            Reach.ladder,
            (reach) => eventReachLabel(l10n, reach),
          ),
          readOnly: readOnly,
        ),
        // What *Extended network* means, while it is the one chosen (#547).
        // The other rungs say who they are in their labels.
        BgeFieldNote<Reach>(
          formControlName: EventCreateControls.reach,
          textKey: reachNoteKey,
          noteFor: (reach) => reach == Reach.extendedNetwork
              ? l10n.eventCreateReachExtendedNetworkNote
              : null,
        ),
        const BgeGap.md(),
        BgeTextField(
          key: descriptionKey,
          formControlName: EventCreateControls.description,
          label: l10n.eventCreateDescription,
          readOnly: readOnly,
          textInputAction: TextInputAction.newline,
          keyboardType: TextInputType.multiline,
          minLines: 2,
          maxLines: 5,
        ),
        const BgeGap.md(),
        BgeTextField(
          key: locationKey,
          formControlName: EventCreateControls.location,
          label: l10n.eventCreateLocation,
          readOnly: readOnly,
        ),
        const BgeGap.md(),
        BgeTextField(
          key: urlKey,
          formControlName: EventCreateControls.url,
          label: l10n.eventCreateUrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          readOnly: readOnly,
          validationMessages: {
            EventCreateErrors.fullLink: (_) => l10n.eventCreateUrlInvalid,
          },
        ),
      ],
    );
  }
}
