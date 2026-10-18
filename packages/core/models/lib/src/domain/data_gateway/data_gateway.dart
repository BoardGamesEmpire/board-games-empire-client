import 'package:freezed_annotation/freezed_annotation.dart';

import 'data_gateway_auth_type.dart';

part 'data_gateway.freezed.dart';

/// A configured connection from the server to an external game-data source,
/// such as a BoardGameGeek bridge (#41).
///
/// Installation configuration, read from the server whenever the admin screen
/// opens and never stored on the device (#41).
///
/// ## What is deliberately not here
///
/// **`authParameters`.** The backend returns a DataGateway's stored credentials
/// on every read until backend#753 makes them write-only. This type has no
/// field for them, so the mapping never reads them, and they cannot reach a
/// log line, a `toString`, or a cache. The breadcrumb scrubber would not catch
/// them, because its default keys do not include that name.
///
/// **Whether it is connected.** The server stores only [enabled]. Connecting
/// sets it before the attempt, so a gateway whose connection failed is still
/// enabled; repeated failures auto-disable it. A connect or disconnect result
/// is answered once, on the response to that action, and is not part of the
/// row.
///
/// The informational fields (icons, website, API version, usage and the
/// timestamps) are not read either, because nothing on the admin screen shows
/// them yet, and a field that is read is one more way for a row to fail to
/// parse.
@freezed
abstract class DataGateway with _$DataGateway {
  const factory DataGateway({
    required String id,

    /// Unique across the server's live DataGateways.
    required String name,
    String? description,

    /// The host the server dials. Not validated as a URL by the backend.
    required String connectionUrl,

    /// 1–65535.
    required int connectionPort,
    required bool enabled,
    required DataGatewayAuthType authType,
  }) = _DataGateway;
}
