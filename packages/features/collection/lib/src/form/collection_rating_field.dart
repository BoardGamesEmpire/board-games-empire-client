import 'package:flutter/material.dart';
import 'package:ui/ui.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

/// The rating dropdown of a collection entry's sheets (#45, #46): 1 to 10,
/// and "No rating" as a choice of its own when [offerNone].
///
/// Package-private: the add and edit sheets share it. It binds to a
/// `FormControl<int>` named [formControlName], whose value is null for none.
class CollectionRatingField extends StatelessWidget {
  const CollectionRatingField({
    required this.formControlName,
    required this.fieldKey,
    required this.busy,
    required this.offerNone,
    super.key,
  });

  final String formControlName;

  /// The key of the dropdown itself, for finders.
  final Key fieldKey;

  /// Whether a write is under way, when the field is read-only.
  final bool busy;

  /// Whether "No rating" is offered. An entry whose rating is set can't be
  /// cleared (#679), so its sheet doesn't offer it.
  final bool offerNone;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);

    return BgeDropdownField<int?>(
      key: fieldKey,
      formControlName: formControlName,
      label: l10n.addToCollectionRatingLabel,
      readOnly: busy,
      items: [
        if (offerNone)
          BgeDropdownItem(value: null, label: l10n.addToCollectionRatingNone),
        for (var rating = 1; rating <= 10; rating++)
          BgeDropdownItem(
            value: rating,
            label: l10n.addToCollectionRatingValue(rating),
          ),
      ],
    );
  }
}
