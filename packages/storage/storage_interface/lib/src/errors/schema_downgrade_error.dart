/// Thrown when a database on disk reports a newer schema version than the
/// running client supports — i.e. an attempted schema *downgrade*.
///
/// Drift routes both upgrades and downgrades through `onUpgrade`. The BGE
/// migration convention refuses the downgrade case rather than attempting to
/// run migrations backwards (which drift cannot do and which risks silent
/// data loss).
///
/// This is a storage-layer *contract* type, deliberately defined in
/// `storage_interface` rather than in a concrete backend: the application
/// layer can catch it while depending only on the storage abstraction. The
/// storage implementation throws it; the app layer catches it, refuses to
/// open the affected database, and surfaces a localized message.
///
/// Localization is the app layer's responsibility. This type carries only the
/// raw version numbers ([onDisk], [supported]) and never any user-facing copy.
/// Suggested ARB key: `storageSchemaDowngradeMessage`, with integer
/// placeholders `{onDisk}` and `{supported}`.
class SchemaDowngradeError implements Exception {
  /// Creates an error describing a refused downgrade from an [onDisk] schema
  /// version to the [supported] one. [onDisk] must be strictly greater than
  /// [supported].
  const SchemaDowngradeError({required this.onDisk, required this.supported})
    : assert(
        onDisk > supported,
        'SchemaDowngradeError is only valid for a downgrade '
        '(onDisk must be greater than supported).',
      );

  /// The schema version found in the on-disk database.
  final int onDisk;

  /// The schema version this client supports and can safely open.
  final int supported;

  @override
  String toString() =>
      'SchemaDowngradeError: on-disk schema v$onDisk is newer than the '
      'supported schema v$supported; refusing to open.';
}
