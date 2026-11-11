import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// One household create as the sender sent it.
typedef HouseholdCreate = ({
  String name,
  String clientRequestId,
  String? description,
});

/// A household remote that answers creates from [respond] and records each
/// one. A create is the only household call the sender makes.
class FakeHouseholdRemote implements HouseholdRemoteDataSource {
  FakeHouseholdRemote(this.respond);

  /// Swappable mid-test, so a server can change its answer.
  FutureOr<Household> Function(HouseholdCreate create) respond;

  final List<HouseholdCreate> creates = [];

  @override
  Future<Household> createHousehold({
    required String name,
    required String clientRequestId,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    final create = (
      name: name,
      clientRequestId: clientRequestId,
      description: description,
    );
    creates.add(create);
    return respond(create);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not a send');
}

/// One event create as the sender sent it (#499).
typedef EventCreate = ({EventDraft draft, String clientRequestId});

/// An event remote that answers creates from [respond] and records each one,
/// before it is answered. A create is the only event call the sender makes.
class FakeEventRemote implements EventRemoteDataSource {
  FakeEventRemote(this.respond);

  /// Swappable mid-test, so a server can change its answer.
  FutureOr<CreatedEvent> Function(EventCreate create) respond;

  final List<EventCreate> creates = [];

  @override
  Future<EventAttendee> updateAttendeeStatus(
    String eventId,
    String attendeeId,
    EventParticipationStatus status, {
    String? notes,
  }) async => throw UnimplementedError('updateAttendeeStatus is not faked');

  @override
  Future<EventAttendee> addAttendee(
    String eventId, {
    required String userId,
    required EventRole role,
  }) async => throw UnimplementedError('addAttendee is not faked');

  @override
  Future<EventAttendee> removeAttendee(
    String eventId,
    String attendeeId,
  ) async => throw UnimplementedError('removeAttendee is not faked');

  @override
  Future<List<OfferedGame>> fetchGamesPool(
    String eventId, {
    required List<String> attendeeIds,
  }) async => throw UnimplementedError('fetchGamesPool is not faked');

  @override
  Future<OfferedGame> offerGame(
    String eventId,
    String attendeeId, {
    required String collectionId,
  }) async => throw UnimplementedError('offerGame is not faked');

  @override
  Future<void> takeBackGame(
    String eventId,
    String attendeeId,
    String offeredGameId,
  ) async => throw UnimplementedError('takeBackGame is not faked');

  @override
  Future<List<EventNomination>> fetchNominations(String eventId) async =>
      throw UnimplementedError('fetchNominations is not faked');

  @override
  Future<EventNomination> fetchNomination(
    String eventId,
    String nominationId,
  ) async => throw UnimplementedError('fetchNomination is not faked');

  @override
  Future<EventNomination> nominate(
    String eventId, {
    required String platformGameId,
    required String suppliedFromId,
    String? occurrenceId,
  }) async => throw UnimplementedError('nominate is not faked');

  @override
  Future<void> castVote(
    String eventId,
    String nominationId, {
    required VoteType voteType,
    String? comment,
  }) async => throw UnimplementedError('castVote is not faked');

  @override
  Future<EventNomination> withdrawNomination(
    String eventId,
    String nominationId,
  ) async => throw UnimplementedError('withdrawNomination is not faked');

  @override
  Future<EventNomination> approveNomination(
    String eventId,
    String nominationId,
  ) async => throw UnimplementedError('approveNomination is not faked');

  @override
  Future<EventNomination> rejectNomination(
    String eventId,
    String nominationId,
  ) async => throw UnimplementedError('rejectNomination is not faked');

  @override
  Future<({EventNomination nomination, NominationResolution resolution})>
  resolveNomination(String eventId, String nominationId) async =>
      throw UnimplementedError('resolveNomination is not faked');

  @override
  Future<CreatedEvent> createEvent(
    EventDraft draft, {
    required String clientRequestId,
  }) async {
    final create = (draft: draft, clientRequestId: clientRequestId);
    creates.add(create);
    return respond(create);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not a send');
}

/// One collection write as the sender sent it: the method, the entry id it
/// named (null for an add), and the fields it carried.
typedef CollectionWrite = ({
  String method,
  String? id,
  Map<String, Object?> fields,
});

/// A collection remote that answers the three writes from [respond] and
/// records each one. Reads are not a send, so they throw.
class FakeCollectionRemote implements GameCollectionRemoteDataSource {
  FakeCollectionRemote(this.respond);

  /// Swappable mid-test, so a server can change its answer.
  FutureOr<GameCollection> Function(CollectionWrite write) respond;

  final List<CollectionWrite> writes = [];

  Future<GameCollection> _write(CollectionWrite write) async {
    writes.add(write);
    return respond(write);
  }

  @override
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    String? releaseId,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
  }) => _write((
    method: 'POST',
    id: null,
    fields: {
      'platformGameId': platformGameId,
      'medium': medium,
      'quantity': quantity,
      'rating': rating,
      'comment': comment,
    },
  ));

  @override
  Future<GameCollection> updateEntry({
    required String id,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
    String? releaseId,
  }) => _write((
    method: 'PATCH',
    id: id,
    fields: {
      'quantity': quantity,
      'rating': rating,
      'comment': comment,
      'favorite': favorite,
      'playAgain': playAgain,
    },
  ));

  @override
  Future<GameCollection> removeEntry(String id, {String? reason}) =>
      _write((method: 'DELETE', id: id, fields: const {}));

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not a send');
}
