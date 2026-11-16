import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';

/// Assembles the signed-in user's export bundle for [server]: the export
/// bundler's `assemble` (`UserDataExportBundler`, which the composition
/// passes in, so this package names no bundler type).
///
/// [refresh] asks every exporter to bring its data up to date first.
///
/// Throws [ExportNotAuthenticatedException] when there is no signed-in
/// session, or when it ended or changed user while the exporters ran, and
/// [ExportSessionUnavailableException] when the session could not be read.
/// Any other failure, such as an exporter's, propagates as it is.
typedef AssembleUserDataExport = Future<UserDataExportBundle> Function(
  ActiveServer server, {
  bool refresh,
});
