import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/meta_database.dart';

@LazySingleton(as: NotificationSummaryRepository)
class NotificationSummaryRepositoryImpl
    implements NotificationSummaryRepository {
  NotificationSummaryRepositoryImpl(this._database);

  final MetaDatabase _database;

  @override
  Future<NotificationSummary> add(NotificationSummary summary) async {
    final now = DateTime.now().toUtc();
    await _database
        .into(_database.notificationSummaries)
        .insert(
          NotificationSummariesCompanion.insert(
            id: summary.id,
            localServerId: summary.localServerId,
            bgeServerId: summary.bgeServerId,
            serverDisplayName: summary.serverDisplayName,
            title: summary.title,
            body: Value(summary.body),
            isRead: Value(summary.isRead),
            requiresFullLoad: Value(summary.requiresFullLoad),
            receivedAt: summary.receivedAt,
            createdAt: now,
          ),
        );
    return (await _getById(summary.id))!;
  }

  @override
  Future<void> markRead(String notificationId) async {
    await (_database.update(_database.notificationSummaries)
          ..where((t) => t.id.equals(notificationId)))
        .write(const NotificationSummariesCompanion(isRead: Value(true)));
  }

  @override
  Future<void> markAllReadForServer(String localServerId) async {
    await (_database.update(_database.notificationSummaries)
          ..where((t) => t.localServerId.equals(localServerId)))
        .write(const NotificationSummariesCompanion(isRead: Value(true)));
  }

  @override
  Future<void> delete(String notificationId) async {
    await (_database.delete(
      _database.notificationSummaries,
    )..where((t) => t.id.equals(notificationId))).go();
  }

  @override
  Future<void> deleteAllForServer(String localServerId) async {
    await (_database.delete(
      _database.notificationSummaries,
    )..where((t) => t.localServerId.equals(localServerId))).go();
  }

  @override
  Future<List<NotificationSummary>> getUnread() async {
    final rows =
        await (_database.select(_database.notificationSummaries)
              ..where((t) => t.isRead.equals(false))
              ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)]))
            .get();
    return rows.map(_mapToModel).toList();
  }

  @override
  Future<List<NotificationSummary>> getForServer(String localServerId) async {
    final rows =
        await (_database.select(_database.notificationSummaries)
              ..where((t) => t.localServerId.equals(localServerId))
              ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)]))
            .get();
    return rows.map(_mapToModel).toList();
  }

  @override
  Future<int> getUnreadCount() async {
    final expr = _database.notificationSummaries.id.count();
    final result =
        await (_database.selectOnly(_database.notificationSummaries)
              ..addColumns([expr])
              ..where(_database.notificationSummaries.isRead.equals(false)))
            .getSingle();
    return result.read(expr) ?? 0;
  }

  @override
  Future<int> getUnreadCountForServer(String localServerId) async {
    final expr = _database.notificationSummaries.id.count();
    final result =
        await (_database.selectOnly(_database.notificationSummaries)
              ..addColumns([expr])
              ..where(
                _database.notificationSummaries.localServerId.equals(
                      localServerId,
                    ) &
                    _database.notificationSummaries.isRead.equals(false),
              ))
            .getSingle();
    return result.read(expr) ?? 0;
  }

  @override
  Stream<List<NotificationSummary>> watchAll() =>
      (_database.select(_database.notificationSummaries)
            ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)]))
          .watch()
          .map((rows) => rows.map(_mapToModel).toList());

  @override
  Stream<int> watchUnreadCount() {
    final expr = _database.notificationSummaries.id.count();
    return (_database.selectOnly(_database.notificationSummaries)
          ..addColumns([expr])
          ..where(_database.notificationSummaries.isRead.equals(false)))
        .watchSingle()
        .map((row) => row.read(expr) ?? 0);
  }

  @override
  Stream<int> watchUnreadCountForServer(String localServerId) {
    final expr = _database.notificationSummaries.id.count();
    return (_database.selectOnly(_database.notificationSummaries)
          ..addColumns([expr])
          ..where(
            _database.notificationSummaries.localServerId.equals(
                  localServerId,
                ) &
                _database.notificationSummaries.isRead.equals(false),
          ))
        .watchSingle()
        .map((row) => row.read(expr) ?? 0);
  }

  Future<NotificationSummary?> _getById(String id) async {
    final row = await (_database.select(
      _database.notificationSummaries,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row != null ? _mapToModel(row) : null;
  }

  NotificationSummary _mapToModel(NotificationSummaryData data) =>
      NotificationSummary(
        id: data.id,
        localServerId: data.localServerId,
        bgeServerId: data.bgeServerId,
        serverDisplayName: data.serverDisplayName,
        title: data.title,
        body: data.body,
        isRead: data.isRead,
        requiresFullLoad: data.requiresFullLoad,
        receivedAt: data.receivedAt,
        createdAt: data.createdAt,
      );
}
