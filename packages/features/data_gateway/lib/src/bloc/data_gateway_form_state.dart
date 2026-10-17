import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the add or edit form is showing (#41).
sealed class DataGatewayFormState extends Equatable {
  const DataGatewayFormState();

  @override
  List<Object?> get props => [];
}

/// The DataGateway being edited is being read.
final class DataGatewayFormLoading extends DataGatewayFormState {
  const DataGatewayFormLoading();
}

/// The user's role may not see DataGateways.
final class DataGatewayFormDenied extends DataGatewayFormState {
  const DataGatewayFormDenied();
}

/// The DataGateway to edit does not exist.
final class DataGatewayFormMissing extends DataGatewayFormState {
  const DataGatewayFormMissing();
}

/// The DataGateway to edit could not be read. Retryable.
final class DataGatewayFormLoadFailed extends DataGatewayFormState {
  const DataGatewayFormLoadFailed();
}

/// The form, empty for an add or filled from [original] for an edit.
final class DataGatewayFormEditing extends DataGatewayFormState {
  const DataGatewayFormEditing({
    this.original,
    this.submitting = false,
    this.mayChange = true,
    this.failure,
  });

  /// The row being edited, as read when the form opened. Null for an add.
  final DataGateway? original;

  final bool submitting;

  /// False once the session has seen a change refused. The form then shows
  /// why instead of a save that would be refused again (#41).
  final bool mayChange;

  /// Why the last save did not happen, until the user edits the form.
  final DataGatewayFormFailure? failure;

  /// The form after one step of a save. The row, and whether the user may
  /// change it, carry over unless [mayChange] says otherwise; [submitting]
  /// and [failure] describe this step alone.
  DataGatewayFormEditing next({
    bool submitting = false,
    bool? mayChange,
    DataGatewayFormFailure? failure,
  }) => DataGatewayFormEditing(
    original: original,
    submitting: submitting,
    mayChange: mayChange ?? this.mayChange,
    failure: failure,
  );

  @override
  List<Object?> get props => [original, submitting, mayChange, failure];
}

/// Why a save did not happen.
enum DataGatewayFormFailure {
  /// An edit changed nothing. Nothing was sent: the server refuses an empty
  /// update.
  nothingChanged,

  /// Another live DataGateway has the name. The server answers this with a
  /// 500 until backend#754, which arrives as [failed].
  nameInUse,

  /// The DataGateway was deleted while it was being edited.
  gone,

  /// The request got no answer that says anything, or the server refused the
  /// values.
  failed,
}

/// The server accepted the save.
final class DataGatewayFormSaved extends DataGatewayFormState {
  const DataGatewayFormSaved({required this.result, required this.created});

  final DataGatewayChangeResult result;

  /// True for an add, false for an edit.
  final bool created;

  @override
  List<Object?> get props => [result, created];
}
