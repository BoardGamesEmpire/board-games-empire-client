import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the DataGateway detail screen is showing (#457).
sealed class DataGatewayDetailState extends Equatable {
  const DataGatewayDetailState();

  @override
  List<Object?> get props => [];
}

/// The row is being read from the server, with no row to show meanwhile.
final class DataGatewayDetailLoading extends DataGatewayDetailState {
  const DataGatewayDetailLoading();
}

/// The server refused the read: the user's role may not see DataGateways.
final class DataGatewayDetailDenied extends DataGatewayDetailState {
  const DataGatewayDetailDenied();
}

/// The read failed for a reason that says nothing about access or about the
/// row. Retryable.
final class DataGatewayDetailFailed extends DataGatewayDetailState {
  const DataGatewayDetailFailed();
}

/// The DataGateway does not exist, or was deleted.
final class DataGatewayDetailGone extends DataGatewayDetailState {
  const DataGatewayDetailGone();
}

/// The server's row.
final class DataGatewayDetailReady extends DataGatewayDetailState {
  const DataGatewayDetailReady({
    required this.gateway,
    this.mayUpdate = false,
    this.busy,
    this.interviewWaiting = false,
    this.outcome,
  });

  final DataGateway gateway;

  /// Whether to offer re-interview and the capability switches: what the
  /// caller's access says of update now (#456), and false while that is
  /// unknown.
  final bool mayUpdate;

  /// The action in flight. There is at most one.
  final DataGatewayDetailBusy? busy;

  /// An interview was asked for during a capability write, and goes when the
  /// write has answered.
  final bool interviewWaiting;

  /// What the last action answered, until the user dismisses it or another
  /// answers. A capability write that works has nothing to report, so it takes
  /// the last outcome down when it answers.
  final DataGatewayDetailOutcome? outcome;

  @override
  List<Object?> get props => [
    gateway,
    mayUpdate,
    busy,
    interviewWaiting,
    outcome,
  ];
}

/// An action in flight on the detail screen.
enum DataGatewayDetailBusy { interview, capabilities }

/// How the last action ended, for the banner above the row.
enum DataGatewayDetailOutcome {
  /// The interview succeeded. The lists it declares load after it, so the
  /// row does not show them yet.
  interviewDone,

  /// The interview ran and did not succeed. The row says why.
  interviewFailed,

  /// No answer in time. The server may still be interviewing.
  interviewUnknown,

  /// The DataGateway is disabled, so the server would not interview it.
  interviewDisabled,

  /// The request got no answer that says anything about the interview. The
  /// server may still be interviewing, so the row is read again.
  interviewNoAnswer,

  /// A capability write got no answer that says anything about it. It may
  /// have applied.
  capabilityFailed,

  /// The server refused the change because of the user's role.
  ///
  /// Since #456 a refusal takes nothing away by itself: it asks the caller's
  /// access again, and the controls follow that answer.
  refused,
}

/// The names to show a switch for: the union of what [gateway] declares and
/// what an admin switched off, the ones this client knows in the server's
/// order, then the rest as sent.
///
/// A name switched off and not declared stays in, so an admin can switch it
/// back on, and a name this client does not know stays as sent, because a
/// write sends the whole list back (#457).
List<String> dataGatewayCapabilityRows(DataGateway gateway) {
  final names = {...gateway.capabilities, ...gateway.disabledCapabilities};
  return [
    for (final name in DataGatewayCapabilities.known)
      if (names.contains(name)) name,
    for (final name in names)
      if (!DataGatewayCapabilities.known.contains(name)) name,
  ];
}

/// The lists to show a row for: the ones [gateway] declares, in the order the
/// server runs their jobs, then any it declares that this client doesn't know
/// of, which only a section can say is a list.
///
/// A list an admin switched off keeps its row, flagged `switchedOff`: the
/// server doesn't load it, and its row says so. Dropping the row would move
/// the switches below up the page under the pointer that just switched it.
///
/// `section` is null for a list whose job has not run since an interview,
/// which means it has not loaded yet, not that it failed (#457).
List<({String capability, DataGatewaySection? section, bool switchedOff})>
dataGatewayListRows(DataGateway gateway) => [
  for (final capability in DataGatewayCapabilities.lists)
    if (gateway.capabilities.contains(capability))
      (
        capability: capability,
        section: gateway.sections
            .where((section) => section.capability == capability)
            .firstOrNull,
        switchedOff: gateway.disabledCapabilities.contains(capability),
      ),
  for (final section in gateway.sections)
    if (!DataGatewayCapabilities.lists.contains(section.capability) &&
        gateway.capabilities.contains(section.capability))
      (
        capability: section.capability,
        section: section,
        switchedOff: gateway.disabledCapabilities.contains(section.capability),
      ),
];
