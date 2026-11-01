import 'package:freezed_annotation/freezed_annotation.dart';

part 'data_gateway_interview.freezed.dart';

/// Why a DataGateway's last interview failed.
///
/// Mirrors the backend's `DataGatewayInterviewFailure` enum
/// (`prisma/models/game/data-gateway.prisma` in `board-games-empire-backend`).
/// The server logs the raw error and sends only this coarse code (#457).
enum DataGatewayInterviewFailureCode {
  /// The interview's ping went unanswered.
  pingFailed,

  /// The DataGateway does not implement Describe.
  describeUnsupported,

  /// Describe failed in some other way.
  describeFailed,

  /// A code this client does not know, so it can say that the interview
  /// failed but not why.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static DataGatewayInterviewFailureCode fromWire(String name) =>
      switch (name) {
        'PingFailed' => DataGatewayInterviewFailureCode.pingFailed,
        'DescribeUnsupported' =>
          DataGatewayInterviewFailureCode.describeUnsupported,
        'DescribeFailed' => DataGatewayInterviewFailureCode.describeFailed,
        _ => DataGatewayInterviewFailureCode.unknown,
      };
}

/// Why a list job failed to load a DataGateway's section.
///
/// Mirrors the backend's `DataGatewaySectionFailure` enum
/// (`prisma/models/game/data-gateway.prisma` in `board-games-empire-backend`).
enum DataGatewaySectionFailureCode {
  /// The DataGateway answered that it does not serve the list.
  listUnsupported,

  /// The list call failed in some other way.
  listFailed,

  /// The server could not write the links.
  linkFailed,

  /// A code this client does not know, so it can say that the list failed to
  /// load but not why.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static DataGatewaySectionFailureCode fromWire(String name) => switch (name) {
    'ListUnsupported' => DataGatewaySectionFailureCode.listUnsupported,
    'ListFailed' => DataGatewaySectionFailureCode.listFailed,
    'LinkFailed' => DataGatewaySectionFailureCode.linkFailed,
    _ => DataGatewaySectionFailureCode.unknown,
  };
}

/// The names the server gives a DataGateway's capabilities.
///
/// A `DataGateway`'s `capabilities` and `disabledCapabilities`, and a
/// [DataGatewaySection]'s `capability`, stay strings and are never mapped to
/// an enum: a server newer than this client may declare a capability it has
/// never heard of, and the row has to carry it as sent (#457).
abstract final class DataGatewayCapabilities {
  static const String search = 'Search';
  static const String fetch = 'Fetch';
  static const String fetchExpansions = 'FetchExpansions';
  static const String listLanguages = 'ListLanguages';
  static const String listPlatforms = 'ListPlatforms';
  static const String listCategories = 'ListCategories';
  static const String listMechanics = 'ListMechanics';

  /// Every capability this client knows of, in the server's order.
  static const List<String> known = [
    search,
    fetch,
    fetchExpansions,
    listLanguages,
    listPlatforms,
    listCategories,
    listMechanics,
  ];

  /// The capabilities that load a list, in the order the server runs their
  /// jobs. Each one a DataGateway declares, and no admin switched off, gets a
  /// [DataGatewaySection] once its job has recorded an outcome, and has none
  /// until then.
  static const List<String> lists = [
    listLanguages,
    listPlatforms,
    listCategories,
    listMechanics,
  ];
}

/// Why a DataGateway's last interview failed, and when.
@freezed
abstract class DataGatewayInterviewFailure with _$DataGatewayInterviewFailure {
  const factory DataGatewayInterviewFailure({
    required DataGatewayInterviewFailureCode code,

    /// When the interview failed.
    required DateTime at,
  }) = _DataGatewayInterviewFailure;
}

/// Where a DataGateway's onboarding stands, as the row's `interview` block
/// says it.
///
/// The server interviews a DataGateway to learn what it serves, and does not
/// use it until one interview has succeeded. The block already applies the
/// server's rule for which failure is current, so the client shows [failure]
/// as it comes and compares no timestamps (#457). It reads the block, never
/// the raw `lastInterview*` columns the block is derived from.
@freezed
abstract class DataGatewayInterviewStatus with _$DataGatewayInterviewStatus {
  const factory DataGatewayInterviewStatus({
    /// Whether an interview has ever succeeded.
    @Default(false) bool interviewed,

    /// The first interview that succeeded.
    DateTime? firstInterviewedAt,

    /// The last interview that succeeded: its answers are the ones in use.
    DateTime? lastInterviewedAt,

    /// The last interview's failure, only while it is current: null once a
    /// later interview succeeded.
    DataGatewayInterviewFailure? failure,
  }) = _DataGatewayInterviewStatus;
}

/// Why a section's list job failed its last attempt, and when.
@freezed
abstract class DataGatewaySectionFailure with _$DataGatewaySectionFailure {
  const factory DataGatewaySectionFailure({
    required DataGatewaySectionFailureCode code,

    /// When the section's job failed its last attempt.
    required DateTime at,
  }) = _DataGatewaySectionFailure;
}

/// One list the server loads from a DataGateway after each interview, such as
/// its languages, and how the last attempt went.
@freezed
abstract class DataGatewaySection with _$DataGatewaySection {
  const factory DataGatewaySection({
    /// The list the section loads, as the server names it. One of
    /// [DataGatewayCapabilities.lists] today; a name this client does not know
    /// stays as sent.
    required String capability,

    /// The last time the section loaded. Null if it never has.
    DateTime? lastLoadedAt,

    /// The last failure, only while it is current: null once a later load
    /// succeeded.
    DataGatewaySectionFailure? failure,
  }) = _DataGatewaySection;
}
