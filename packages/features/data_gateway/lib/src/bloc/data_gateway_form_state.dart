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
    this.maySave = false,
    this.accessKnown = false,
    this.failure,
  });

  /// The row being edited, as read when the form opened. Null for an add.
  final DataGateway? original;

  final bool submitting;

  /// Whether to offer the save: what the caller's access says now (#456),
  /// create for an add and update for an edit, and false while that is
  /// unknown. Without it the fields are read-only.
  final bool maySave;

  /// Whether the caller's access has answered. Without the save, a known
  /// answer is a refusal and the form says so in the save's place; an
  /// unknown one says nothing yet, because nothing about the role is known
  /// (#456).
  final bool accessKnown;

  /// Why the last save did not happen, until the user edits the form.
  final DataGatewayFormFailure? failure;

  /// The form after one step of a save. The row, and what access says,
  /// carry over unless [maySave] and [accessKnown] say otherwise;
  /// [submitting] and [failure] describe this step alone.
  DataGatewayFormEditing next({
    bool submitting = false,
    bool? maySave,
    bool? accessKnown,
    DataGatewayFormFailure? failure,
  }) => DataGatewayFormEditing(
    original: original,
    submitting: submitting,
    maySave: maySave ?? this.maySave,
    accessKnown: accessKnown ?? this.accessKnown,
    failure: failure,
  );

  @override
  List<Object?> get props => [
    original,
    submitting,
    maySave,
    accessKnown,
    failure,
  ];
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

  /// The server refused the save because of the caller's role.
  ///
  /// Since #456 a refused save no longer hides the save: it asks the
  /// caller's access again, and the form follows that answer. Until the
  /// answer says otherwise the save stays offered, so the refusal is said
  /// here, above it, or the user would get no answer at all.
  refused,

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
