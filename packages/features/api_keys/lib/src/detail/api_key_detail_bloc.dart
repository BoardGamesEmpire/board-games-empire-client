import 'package:api_keys/src/detail/api_key_detail_event.dart';
import 'package:api_keys/src/detail/api_key_detail_state.dart';
import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Drives one API key's own page (#1028): reads the key, and enables,
/// disables, edits or deletes it.
///
/// Nothing is stored. [ApiKeyDetailRequested] reads the key and the
/// permissions the user may grant together. A 404 is [ApiKeyDetailStatus.gone]
/// and any other failure [ApiKeyDetailStatus.loadFailed], with why in
/// [ApiKeyDetailState.loadFailure]. The grantable permissions only describe
/// the key's scopes, so a failed read of them leaves them null and never
/// fails the page.
///
/// ## Writes
///
/// Each goes straight to the server: the page is online-only. One is on its
/// way at a time, in [ApiKeyDetailState.writing], and an event for another
/// meanwhile is dropped, as is one before the key has loaded or once it is
/// deleted. A read is dropped while a write is out, as its answer could land
/// after the write's and show the key as it was.
///
/// - A toggle sends `enabled` alone and shows the key the server answers.
///   A toggle to the value the key already has sends nothing.
/// - A save sends what [ApiKeySaveRequested] names, and nothing it leaves
///   null. One that names nothing sends nothing, and is
///   [ApiKeyDetailNothingToSave]. One that goes through shows the key the
///   server answers, [ApiKeyDetailSaved].
/// - A delete that goes through keeps the key, so the page draws it as it
///   leaves, and marks the state [ApiKeyDetailState.deleted].
/// - A 404 from any of them says the key is gone. Any other failure keeps the
///   key as it was, with an [ApiKeyDetailFailed] naming the write.
///
/// `confirmCritical` is sent only when a save carries it. When the server
/// refuses a save that didn't, saying it adds a Critical permission, the
/// permissions the page was built from are out of date: they are read again
/// before the failure is emitted, so that the page's question can name what
/// is Critical now. A failed read keeps the ones it had.
///
/// A write starting retires the last write's outcome, which no longer
/// describes what the page shows.
class ApiKeyDetailBloc extends Bloc<ApiKeyDetailEvent, ApiKeyDetailState> {
  ApiKeyDetailBloc(this._remote, {required this._id})
    : super(const ApiKeyDetailState()) {
    on<ApiKeyDetailRequested>(_onRequested, transformer: restartable());
    on<ApiKeyEnabledChanged>(_onEnabledChanged);
    on<ApiKeyDeleteRequested>(_onDeleteRequested);
    on<ApiKeySaveRequested>(_onSaveRequested);
    on<ApiKeyDetailOutcomeCleared>(_onOutcomeCleared);
  }

  final ApiKeyRemoteDataSource _remote;

  /// The key this page is about.
  final String _id;

  /// Whether a write may start now.
  bool get _mayWrite =>
      state.status == ApiKeyDetailStatus.loaded &&
      state.writing == null &&
      !state.deleted;

  Future<void> _onRequested(
    ApiKeyDetailRequested event,
    Emitter<ApiKeyDetailState> emit,
  ) async {
    if (state.writing != null || state.deleted) return;
    // A bloc's first emit is not compared with its initial state, so the
    // spinner it starts on is not emitted again.
    if (state.status != ApiKeyDetailStatus.loading) {
      emit(const ApiKeyDetailState());
    }
    // Both start before either is awaited.
    final grantable = _readGrantable();
    final ApiKey key;
    try {
      key = await _remote.fetch(_id);
    } on ApiKeyNotFoundException {
      if (emit.isDone) return;
      emit(const ApiKeyDetailState(status: ApiKeyDetailStatus.gone));
      return;
    } on Object catch (error) {
      if (emit.isDone) return;
      emit(
        ApiKeyDetailState(
          status: ApiKeyDetailStatus.loadFailed,
          loadFailure: apiKeyFailureOf(error),
        ),
      );
      return;
    }
    final permissions = await grantable;
    // A read asked for since has taken this one's place.
    if (emit.isDone) return;
    emit(
      ApiKeyDetailState(
        status: ApiKeyDetailStatus.loaded,
        key: key,
        grantable: permissions,
      ),
    );
  }

  /// The permissions the user may grant, by slug, or null when the read
  /// fails. Never throws.
  Future<Map<String, GrantablePermission>?> _readGrantable() async {
    try {
      final permissions = await _remote.fetchGrantable();
      return {
        for (final permission in permissions) permission.slug: permission,
      };
    } on Object {
      return null;
    }
  }

  Future<void> _onEnabledChanged(
    ApiKeyEnabledChanged event,
    Emitter<ApiKeyDetailState> emit,
  ) async {
    if (!_mayWrite || state.key!.enabled == event.enabled) return;
    emit(
      state.copyWith(writing: () => ApiKeyWrite.toggle, outcome: () => null),
    );
    try {
      final answered = await _remote.update(
        _id,
        ApiKeyPatch(enabled: event.enabled),
      );
      emit(state.copyWith(key: answered, writing: () => null));
    } on Object catch (error) {
      _failed(emit, error, ApiKeyWrite.toggle);
    }
  }

  Future<void> _onDeleteRequested(
    ApiKeyDeleteRequested event,
    Emitter<ApiKeyDetailState> emit,
  ) async {
    if (!_mayWrite) return;
    emit(
      state.copyWith(writing: () => ApiKeyWrite.delete, outcome: () => null),
    );
    try {
      await _remote.delete(_id);
      emit(
        state.copyWith(
          writing: () => null,
          deleted: true,
          outcome: () => const ApiKeyDetailDeleted(),
        ),
      );
    } on Object catch (error) {
      _failed(emit, error, ApiKeyWrite.delete);
    }
  }

  Future<void> _onSaveRequested(
    ApiKeySaveRequested event,
    Emitter<ApiKeyDetailState> emit,
  ) async {
    if (!_mayWrite) return;
    final patch = ApiKeyPatch(
      name: event.name,
      scopes: event.scopes,
      expiresInDays: event.expiresInDays,
      confirmCritical: event.confirmCritical,
    );
    // The remote refuses an empty patch, and there is nothing to send.
    if (patch.isEmpty) {
      emit(state.copyWith(outcome: () => const ApiKeyDetailNothingToSave()));
      return;
    }
    emit(state.copyWith(writing: () => ApiKeyWrite.save, outcome: () => null));
    try {
      final answered = await _remote.update(_id, patch);
      emit(
        state.copyWith(
          key: answered,
          writing: () => null,
          outcome: () => const ApiKeyDetailSaved(),
        ),
      );
    } on ApiKeyCriticalNeedsConfirmationException catch (error) {
      // Unconfirmed, the page found nothing new and Critical to ask about,
      // and the server did: what the page was built from has changed under
      // it.
      final grantable = event.confirmCritical ? null : await _readGrantable();
      _failed(emit, error, ApiKeyWrite.save, grantable: grantable);
    } on Object catch (error) {
      _failed(emit, error, ApiKeyWrite.save);
    }
  }

  /// Settles [write] after it threw [error]: gone on a 404, and otherwise the
  /// key as it was, with the failure, and [grantable] when it was read again.
  void _failed(
    Emitter<ApiKeyDetailState> emit,
    Object error,
    ApiKeyWrite write, {
    Map<String, GrantablePermission>? grantable,
  }) {
    final failure = apiKeyFailureOf(error);
    if (failure.reason == ApiKeyFailureReason.notFound) {
      emit(const ApiKeyDetailState(status: ApiKeyDetailStatus.gone));
      return;
    }
    emit(
      state.copyWith(
        grantable: grantable == null ? null : () => grantable,
        writing: () => null,
        outcome: () => ApiKeyDetailFailed(failure, write: write),
      ),
    );
  }

  void _onOutcomeCleared(
    ApiKeyDetailOutcomeCleared event,
    Emitter<ApiKeyDetailState> emit,
  ) {
    if (state.outcome != null) emit(state.copyWith(outcome: () => null));
  }
}
