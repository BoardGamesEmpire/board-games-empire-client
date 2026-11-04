import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:logging/logging.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

const Set<ResourceType> dataGatewayOnly = {ResourceType.dataGateway};

/// An answer that denies every action.
const Map<ResourceType, ResourceAccess> noneAnswer = {
  ResourceType.dataGateway: ResourceAccess.none,
};

/// An answer that allows every action.
const Map<ResourceType, ResourceAccess> allAnswer = {
  ResourceType.dataGateway: ResourceAccess(
    create: AccessExtent.all,
    read: AccessExtent.all,
    update: AccessExtent.all,
    delete: AccessExtent.all,
    manage: AccessExtent.all,
  ),
};

/// Answers each access request with the next of [replies]: an answer, a
/// [Completer] the test completes when it chooses, or an error to fail with.
/// Records the types each request asked about.
class FakeUserRemote implements UserRemoteDataSource {
  final replies = <Object>[];
  final asked = <Set<ResourceType>>[];

  int get requests => asked.length;

  @override
  Future<Map<ResourceType, ResourceAccess>> fetchAccess(
    Set<ResourceType> resourceTypes,
  ) {
    asked.add(resourceTypes);
    if (replies.isEmpty) {
      return Future.error(StateError('No reply was scripted'));
    }
    return switch (replies.removeAt(0)) {
      final Map<ResourceType, ResourceAccess> answer => Future.value(answer),
      final Completer<Map<ResourceType, ResourceAccess>> pending =>
        pending.future,
      final Object error => Future.error(error),
    };
  }

  @override
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = UserRemoteDataSource.maxSearchPageSize,
  }) => throw UnimplementedError();
}

/// Answers [confirm] with [answer], or with [held] once the test completes
/// it, recording whom it was asked about.
class FakeGuard implements SessionIdentityGuard {
  FakeGuard([this.answer = SessionConfirmation.confirmed]);

  SessionConfirmation answer;
  Completer<SessionConfirmation>? held;
  final askedFor = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    askedFor.add(userId);
    return held?.future ?? answer;
  }
}

/// The log records of loggers named [name] or below it, captured off
/// [Logger.root] for the rest of the test, with the root level restored
/// afterwards.
List<LogRecord> captureLogs(String name) {
  final records = <LogRecord>[];
  final previous = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) {
    if (r.loggerName == name || r.loggerName.startsWith('$name.')) {
      records.add(r);
    }
  });
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = previous;
  });
  return records;
}
