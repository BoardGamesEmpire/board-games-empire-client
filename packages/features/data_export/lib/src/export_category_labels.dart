import 'package:flutter/widgets.dart';

/// A category's display name and description on the export screen (#93).
typedef ExportCategoryLabels = ({String name, String description});

/// Resolves an exporter's label key against the owning feature's strings, or
/// answers null when [key] is not one of that feature's keys.
///
/// Each feature that registers an exporter provides one, so the screen needs
/// no dependency on the features whose data it lists.
typedef ExportCategoryLabelResolver = ExportCategoryLabels? Function(
  BuildContext context,
  String key,
);

/// The first non-null answer among [resolvers] for [key].
///
/// With none, the key itself as the name and no description, so a row is
/// never blank.
ExportCategoryLabels resolveExportCategoryLabels(
  BuildContext context,
  String key,
  List<ExportCategoryLabelResolver> resolvers,
) {
  for (final resolve in resolvers) {
    final labels = resolve(context, key);
    if (labels != null) return labels;
  }
  return (name: key, description: '');
}
