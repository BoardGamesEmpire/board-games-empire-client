import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_state.dart';
import 'package:game_catalog/src/search/data_gateway_search_grant.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Reads a game's expansions from the DataGateways and holds which of them
/// the user ticked (#713, #712).
///
/// The owner calls [load] when the checklist is shown, and again for a retry.
/// A 403 makes the checklist [ExpansionChecklistRefused]. For a DataGateway
/// result it means this user may not ask the DataGateways, so it is recorded
/// on the grant and nothing asks again this session. For a game on this
/// server it may instead mean the user may not read that game, so the grant
/// is left as it is.
class ExpansionChecklistCubit extends Cubit<ExpansionChecklistState> {
  ExpansionChecklistCubit({
    required this._remote,
    required this._target,
    required this._tickOnServer,
    this._grant,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.catalog.expansions'),
       super(const ExpansionChecklistLoading());

  final GamesRemoteDataSource _remote;
  final GameExpansionsTarget _target;
  final DataGatewaySearchGrant? _grant;
  final BgeLogger _logger;

  /// Whether a game the server already holds can be ticked. A search result
  /// passes whether the server holds the result itself (`hit.isOnServer`):
  /// its Re-import imports the game again, and a ticked expansion the server
  /// holds is updated with it, while a first import leaves such an expansion
  /// unticked (#713).
  final bool _tickOnServer;

  /// Reads the expansions, with nothing ticked.
  Future<void> load() async {
    if (state is! ExpansionChecklistLoading) {
      emit(const ExpansionChecklistLoading());
    }
    try {
      final results = await _remote.fetchExpansions(_target);
      if (isClosed) return;
      emit(ExpansionChecklistReady(results: results, ticked: const {}));
    } on GamesForbiddenException catch (e) {
      if (_target is DataGatewayExpansionsTarget) _grant?.refuse(e.apiMessage);
      if (isClosed) return;
      emit(const ExpansionChecklistRefused());
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Reading expansions failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (isClosed) return;
      emit(const ExpansionChecklistFailed());
    }
  }

  /// Whether [hit] can be ticked.
  bool isTickable(GameSearchHit hit) => _tickOnServer || !hit.isOnServer;

  /// Ticks or unticks a row. A row that can't be ticked stays as it is.
  void toggle(String gatewayId, String externalId) {
    final current = state;
    if (current is! ExpansionChecklistReady) return;
    final row = _rows(current, gatewayId).where(
      (hit) => hit.externalId == externalId,
    );
    if (row.isEmpty || !isTickable(row.first)) return;
    final now = {...(current.ticked[gatewayId] ?? const <String>{})};
    if (!now.remove(externalId)) now.add(externalId);
    _emitTicked(current, gatewayId, now);
  }

  /// Ticks every tickable row of a DataGateway, or clears them.
  void setAll(String gatewayId, {required bool ticked}) {
    final current = state;
    if (current is! ExpansionChecklistReady) return;
    _emitTicked(current, gatewayId, {
      if (ticked)
        for (final hit in _rows(current, gatewayId))
          if (isTickable(hit)) hit.externalId,
    });
  }

  /// The External IDs ticked in a DataGateway, in the order of its rows.
  List<String> tickedIn(String gatewayId) {
    final current = state;
    if (current is! ExpansionChecklistReady) return const [];
    final ticked = current.ticked[gatewayId] ?? const <String>{};
    return [
      for (final hit in _rows(current, gatewayId))
        if (ticked.contains(hit.externalId)) hit.externalId,
    ];
  }

  /// Every listed expansion's title, by External ID.
  Map<String, String> get titlesByExternalId {
    final current = state;
    if (current is! ExpansionChecklistReady) return const {};
    return {
      for (final hits in current.results.byDataGateway.values)
        for (final hit in hits) hit.externalId: hit.title,
    };
  }

  static List<GameSearchHit> _rows(
    ExpansionChecklistReady state,
    String gatewayId,
  ) => state.results.byDataGateway[gatewayId] ?? const [];

  void _emitTicked(
    ExpansionChecklistReady current,
    String gatewayId,
    Set<String> now,
  ) => emit(
    ExpansionChecklistReady(
      results: current.results,
      ticked: {
        for (final MapEntry(:key, :value) in current.ticked.entries)
          if (key != gatewayId) key: value,
        if (now.isNotEmpty) gatewayId: now,
      },
    ),
  );
}
