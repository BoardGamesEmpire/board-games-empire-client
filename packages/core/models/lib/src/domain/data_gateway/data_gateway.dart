import 'package:freezed_annotation/freezed_annotation.dart';

import 'data_gateway_auth_type.dart';
import 'data_gateway_interview.dart';

part 'data_gateway.freezed.dart';

/// A configured connection from the server to an external game-data source,
/// such as a BoardGameGeek bridge (#41).
///
/// Installation configuration, read from the server whenever the admin screen
/// opens and never stored on the device (#41).
///
/// ## What is deliberately not here
///
/// **`authParameters`.** Since backend#753 the server no longer sends a
/// DataGateway's stored credentials at all: a row says only whether it has
/// any, and this type does not read even that. It has no field for them, so a
/// server that sent them again could not put them in a log line, a
/// `toString`, or a cache. The breadcrumb scrubber would not catch them,
/// because its default keys do not include that name.
///
/// **Whether it is connected.** The server stores only [enabled]. Connecting
/// sets it before the attempt, so a gateway whose connection failed is still
/// enabled; repeated failures auto-disable it. A connect or disconnect result
/// is answered once, on the response to that action, and is not part of the
/// row. What a row does say is whether the server uses the gateway yet:
/// [interview] holds how its interviews went, and the server does not use a
/// DataGateway until one has succeeded.
///
/// The informational fields (icons, website, API version, usage, coverage, the
/// formats it speaks, and when the row was created or changed) are not read
/// either, because nothing on the admin screen shows them yet, and a field
/// that is read is one more way for a row to fail to parse. Nor are the raw
/// `lastInterview*` columns: [interview] holds what they say, with the
/// server's rule for which failure is current already applied.
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

    /// Whether the server uses this DataGateway yet, and how its interviews
    /// went.
    ///
    /// This and the three fields below default to nothing known, so a fake row
    /// can leave them out. The mapping always sets all four.
    @Default(DataGatewayInterviewStatus()) DataGatewayInterviewStatus interview,

    /// The list jobs that have run since an interview: one per list the
    /// DataGateway declares and no admin switched off, in the order they run.
    @Default(<DataGatewaySection>[]) List<DataGatewaySection> sections,

    /// What the DataGateway declared at its last interview, spelled as the
    /// server spells them ([DataGatewayCapabilities]). A name this client does
    /// not know stays as sent.
    @Default(<String>[]) List<String> capabilities,

    /// The capabilities an admin switched off, spelled as [capabilities] are.
    /// The server does not route them, and no interview changes this list.
    @Default(<String>[]) List<String> disabledCapabilities,
  }) = _DataGateway;
}
