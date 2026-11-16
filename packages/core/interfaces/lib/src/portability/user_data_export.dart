/// One category's exported data (#48).
final class UserDataExport {
  const UserDataExport(this.data, {this.confirmed = true});

  /// The JSON-object payload placed under the exporter's key.
  final Map<String, Object?> data;

  /// `false` when [data] is this device's copy and the server hasn't
  /// confirmed it is current: no recent pass reached the server, so changes
  /// made elsewhere may be missing.
  ///
  /// About what may be missing, not what is added. Changes made on this
  /// device and not yet synced are the user's data, are in [data], and
  /// leave this `true`.
  final bool confirmed;
}
