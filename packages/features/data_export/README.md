# data_export

"Export your data" (#93): the signed-in user saves a copy of their data on
the active server as a JSON file (GDPR Article 20, #11).

## Shape

- `DataExportScreen`: the page. It names the server by the name the server
  gives itself, lists what the file holds, one row per exporter, and offers
  Export. It owns its cubit.
- `DataExportCubit`: assembles the bundle through an
  `AssembleUserDataExport`, the export bundler's `assemble`, and saves it
  through `UserDataExportSink`. A bundle with data the server
  didn't confirm waits for the user to refresh and export, or to save this
  device's copy as it is. A press while a run is out does nothing, and an
  answer lands no sooner than `answerDwell` after its run went busy.
- `resolveExportCategoryLabels`: a row's name and description, from the
  resolvers each exporting feature provides. A key none of them knows shows
  as the key, so a row is never blank.

Everything else it consumes comes from `package:interfaces/portability.dart`.
The shell passes in the bundler's `assemble`, so this package names no
bundler type and never imports `package:di`; the composition roots provide
the sink and the exporters.
