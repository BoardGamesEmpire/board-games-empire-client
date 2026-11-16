import 'package:flutter/widgets.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/export/game_collection_exporter.dart';

/// The collection category's display name and description for the export
/// screen (#93), or null when [key] is not one of the collection exporter's
/// label keys.
///
/// Either key returns both strings, so a screen asking with the exporter's
/// `categoryNameKey` gets the description in the same call.
({String name, String description})? gameCollectionExportLabels(
  BuildContext context,
  String key,
) {
  if (key != GameCollectionExporter.nameLabelKey &&
      key != GameCollectionExporter.descriptionLabelKey) {
    return null;
  }
  final l10n = GameCollectionLocalizations.of(context);
  return (
    name: l10n.collectionExportName,
    description: l10n.collectionExportDescription,
  );
}
