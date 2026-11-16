import 'package:interfaces/src/orchestration/active_server_scope.dart';
import 'package:interfaces/src/portability/user_data_export.dart';

/// A single exportable category of the current user's data (GDPR
/// Article 20 — right to data portability, #11).
///
/// One exporter per data category, owned and registered by the feature
/// package that owns the data (the collection feature registers
/// `GameCollectionExporter` (#48); auth registers `ProfileExporter`
/// (#91)). Registration happens at composition time via
/// `UserDataExportRegistry`; the bundled output is assembled by
/// `UserDataExportBundler`.
///
/// ## Payload convention
///
/// - The payload is ALWAYS a JSON **object** envelope. Collections nest
///   inside a field (e.g. `{"entries": [...]}`) — never a bare
///   top-level list. This keeps every category forward-extensible
///   without a breaking bundle-schema change.
/// - Exporters emit the user's *data*, not client bookkeeping: pure
///   sync-state fields (`isDirty`, `isLocalOnly`) are stripped, and
///   tombstoned (soft-deleted) rows are excluded, mirroring read-path
///   semantics — a removed entry is not owned.
/// - Credentials (session tokens, password material) are NEVER
///   exported. Those are credentials, not user data.
///
/// ## Offline
///
/// Exporters read the local cache and must work offline. Returning
/// `null` means the category doesn't exist on this server and omits it
/// from the bundle entirely; an empty category still exports, as an
/// empty payload.
abstract interface class UserDataExporter {
  /// Stable identifier used as this category's key under the bundle's
  /// top-level `categories` object. camelCase, no spaces — e.g.
  /// `"gameCollection"`, `"households"`, `"profile"`.
  String get key;

  /// l10n key for this category's human-readable title, resolved by the
  /// export-confirmation UI (#93) against the owning feature's ARB.
  ///
  /// Interfaces stay locale-agnostic: never a literal display string.
  /// Labels co-locate with the exporter that owns the category.
  String get categoryNameKey;

  /// l10n key for this category's human-readable description, resolved
  /// by the export-confirmation UI (#93) against the owning feature's
  /// ARB.
  String get descriptionKey;

  /// Produces the JSON-object representation of the current user's data
  /// for this category, scoped to [server] (per-server: each server's
  /// admin is the data controller for that server's data).
  ///
  /// [refresh] asks the exporter to bring its cache up to date before it
  /// reads. The result's [UserDataExport.confirmed] is `false` when the
  /// data is this device's copy and the server hasn't confirmed it is
  /// current. An exporter may wait on the network either way, but only for
  /// a bounded time: past that it answers with its copy, unconfirmed.
  ///
  /// Returns `null` when the category doesn't exist on this server (an
  /// empty category still exports, as an empty payload).
  ///
  /// Errors propagate to the caller: a GDPR export must be complete or
  /// fail legibly — silently omitting a category is a correctness
  /// hazard.
  Future<UserDataExport?> export(ActiveServer server, {bool refresh = false});
}
