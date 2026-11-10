import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/data_gateway/data_gateway.dart';

part 'data_gateway_interview_result.freezed.dart';

/// What an interview an admin asked for answered (#457).
///
/// An interview the server could not complete still answers 2xx, with
/// `success: false` in its response. That is a [succeeded] of false, not an
/// exception, the same way a failed connect is an attempt that did not
/// succeed.
@freezed
abstract class DataGatewayInterviewResult with _$DataGatewayInterviewResult {
  const factory DataGatewayInterviewResult({
    /// The row read again after the interview, whatever its outcome. Its
    /// `interview` already records a failure, so this is where to read why.
    required DataGateway dataGateway,

    /// Whether the interview succeeded. When it did not, the server sends
    /// generic copy and keeps the coordinator's error in its own log, so the
    /// client shows its own words for the outcome.
    required bool succeeded,
  }) = _DataGatewayInterviewResult;
}
