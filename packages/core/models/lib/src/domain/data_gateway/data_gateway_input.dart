import 'package:freezed_annotation/freezed_annotation.dart';

import 'data_gateway.dart';

part 'data_gateway_input.freezed.dart';

/// The values the add and edit forms collect for a DataGateway (#41).
///
/// Already trimmed and validated by the form. There is no credentials field:
/// the client creates every DataGateway with the "None" auth type, because no
/// other type connects yet (#41).
@freezed
abstract class DataGatewayInput with _$DataGatewayInput {
  const factory DataGatewayInput({
    required String name,
    required String connectionUrl,
    required int connectionPort,

    /// Null when the field was left blank.
    String? description,
  }) = _DataGatewayInput;
}

/// The fields an edit changed, and nothing else (#41).
///
/// A null field was left as it was. An edit sends only these, so a field the
/// form did not touch cannot overwrite a change someone else made since the
/// row was read.
@freezed
abstract class DataGatewayChanges with _$DataGatewayChanges {
  const DataGatewayChanges._();

  const factory DataGatewayChanges({
    String? name,
    String? connectionUrl,
    int? connectionPort,

    /// The new description. An **empty string clears it**: null already
    /// means "unchanged", so emptying the field needs a value of its own.
    String? description,
  }) = _DataGatewayChanges;

  /// What [input] changes about [original].
  ///
  /// A blank description in the input against a set one in the original is a
  /// change to empty, which clears it.
  factory DataGatewayChanges.between(
    DataGateway original,
    DataGatewayInput input,
  ) {
    final before = original.description ?? '';
    final after = input.description ?? '';
    return DataGatewayChanges(
      name: input.name == original.name ? null : input.name,
      connectionUrl: input.connectionUrl == original.connectionUrl
          ? null
          : input.connectionUrl,
      connectionPort: input.connectionPort == original.connectionPort
          ? null
          : input.connectionPort,
      description: after == before ? null : after,
    );
  }

  /// Whether nothing changed. The server refuses an empty update with a 400.
  bool get isEmpty =>
      name == null &&
      connectionUrl == null &&
      connectionPort == null &&
      description == null;
}
