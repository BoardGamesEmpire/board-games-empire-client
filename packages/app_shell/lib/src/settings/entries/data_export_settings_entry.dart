import 'package:app_shell/src/router/app_router.dart';
import 'package:app_shell/src/settings/settings_entry.dart';
import 'package:data_export/data_export.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';

/// The per-server Settings row that opens the export screen (#93).
///
/// [serverName] is the name the server gives itself: the name the export file
/// carries, and the one the screen uses.
class DataExportSettingsEntry implements SettingsEntry {
  const DataExportSettingsEntry({required this.serverName});

  final String serverName;

  @override
  String get id => 'dataExport';

  @override
  Widget build(BuildContext context) {
    final l10n = DataExportLocalizations.of(context);
    return BgeRowFocusRing(
      builder: (context, row) => ListTile(
        key: const Key('settings_data_export'),
        focusNode: row.focusNode,
        onFocusChange: row.onFocusChange,
        focusColor: row.focusColor,
        title: Text(l10n.dataExportSettingsTitle),
        subtitle: Text(l10n.dataExportSettingsSubtitle(serverName)),
        // Decorative: it adds nothing to the row's name.
        trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
        onTap: row.onTap(() => context.push(AppRoutes.settingsExport)),
      ),
    );
  }
}
