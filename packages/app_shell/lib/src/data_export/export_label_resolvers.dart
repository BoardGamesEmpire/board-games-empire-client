import 'package:data_export/data_export.dart';
import 'package:game_collection/game_collection.dart';

/// The label resolvers for every exporter the roots register (#93), in the
/// order the export screen asks them. A feature that registers an exporter
/// adds its resolver here.
const List<ExportCategoryLabelResolver> bgeExportCategoryLabelResolvers = [
  gameCollectionExportLabels,
];
