import 'package:dio_network/src/network/json_reads.dart';
import 'package:dio_network/src/network/non_empty_string.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:dio_network/src/network/user_projection.dart';
import 'package:models/domain.dart';

// ── Mapping ─────────────────────────────────────────────────────────
//
// Field by field and not generated, so the mapping reads only what the
// models hold. The rows carry more: the cancellation, deletion and
// recurrence fields, and a guest's email address, none of which is read
// (#496).

/// Maps one row of the list: the event with the occurrences and policy the
/// list embeds.
///
/// No `attendees` key is read. The list serves no roster, so the snapshot
/// says it was not asked, whatever a row carries. The caller's own
/// `attendance` is read (#667).
EventSnapshot mapListRow(Map<String, dynamic> json) => EventSnapshot(
  event: mapEvent(json),
  occurrences: _mapOccurrences(json['occurrences']),
  policy: mapPolicy(json['policy'], served: false),
  attendance: _mapAttendance(json['attendance']),
);

/// Maps the detail's event: the parts of a list row, and the roster.
///
/// `occurrencePolicies` is the dates' own rules (#1009). The detail read
/// always serves them, `[]` when the caller may not read the policy, so with
/// [servesDateRules] a missing one is a contract break: read as null, it
/// would leave the cached rules standing. The create's answer has none, so
/// there a missing key is null; a present one must be a list.
///
/// The roster must be a list. An empty one is a caller who may not read the
/// roster, and a missing or mistyped one is a contract breach: reading it as
/// "nobody" would pass a payload this client failed to read off as an event
/// with no one on it.
EventSnapshot mapDetail(
  Map<String, dynamic> json, {
  required bool servesDateRules,
}) => EventSnapshot(
  event: mapEvent(json),
  occurrences: _mapOccurrences(json['occurrences']),
  policy: mapPolicy(json['policy'], served: true),
  occurrencePolicies: servesDateRules || json['occurrencePolicies'] != null
      ? mapObjects(
          json['occurrencePolicies'],
          field: 'occurrencePolicies',
          item: _mapOccurrencePolicy,
        )
      : null,
  attendees: mapObjects(
    json['attendees'],
    field: 'attendees',
    item: mapAttendee,
  ),
  attendance: _mapAttendance(json['attendance']),
);

/// One nomination as the server serves it (#517).
///
/// The game's title, thumbnail and platform come from the nested
/// `platformGame`; the supplying pool row's id is the `suppliedFromId`
/// column. A nominator who is a guest has no `user`, so no username. An
/// empty thumbnail is none. The `priority` the votes carry is not read. A
/// vote with no `eligible` fails its cast, a [TypeError] that [parseRemote]
/// turns into a contract break, as it does any field this can't read: the
/// server marks every vote, so a missing mark is not a vote that counts.
EventNomination mapNomination(Map<String, dynamic> json) {
  final platformGame = requireObject(json['platformGame'], 'platformGame');
  final game = requireObject(platformGame['game'], 'platformGame.game');
  final platform = requireObject(
    platformGame['platform'],
    'platformGame.platform',
  );
  final nominatedBy = json['nominatedBy'];
  final user = nominatedBy is Map<String, dynamic> ? nominatedBy['user'] : null;
  final username = user is Map<String, dynamic>
      ? user['username'] as String?
      : null;
  final thumbnail = game['thumbnail'] as String?;
  final pausedFrom = json['pausedFrom'] as String?;
  final elevatedTo = json['elevatedTo'];
  return EventNomination(
    id: json['id'] as String,
    eventId: json['eventId'] as String,
    occurrenceId: json['occurrenceId'] as String?,
    platformGameId: json['platformGameId'] as String,
    gameId: game['id'] as String,
    title: game['title'] as String,
    platformName: platform['name'] as String,
    thumbnail: thumbnail == null || thumbnail.isEmpty ? null : thumbnail,
    subtitle: game['subtitle'] as String?,
    elevatedTo: elevatedTo == null
        ? null
        : _mapLineupLink(requireObject(elevatedTo, 'elevatedTo')),
    status: NominationStatus.fromWire(json['status'] as String),
    pausedFrom: pausedFrom == null
        ? null
        : NominationStatus.fromWire(pausedFrom),
    votingDeadline: dateOrNull(json['votingDeadline']),
    nominatedById: json['nominatedById'] as String,
    nominatedByUsername: username,
    suppliedFromId: json['suppliedFromId'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    votes: mapObjects(
      json['votes'],
      field: 'votes',
      item: _mapNominationVote,
    ),
  );
}

LineupLink _mapLineupLink(Map<String, dynamic> json) =>
    (id: json['id'] as String, occurrenceId: json['occurrenceId'] as String?);

/// One lineup game as the server serves it (#519, #920).
///
/// The game's title, subtitle, thumbnail and platform come from the nested
/// `platformGame`; an empty thumbnail is none. `suppliedBy` is the pool
/// row, `{ id, attendeeId, attendee }`. The supplier's name comes from its
/// `attendee` as the roster reads an attendee's: display name, else
/// username, else the guest's name. The attendee is null for a caller who
/// cannot read them, and so is the name.
LineupGame mapLineupGame(Map<String, dynamic> json) {
  final platformGame = requireObject(json['platformGame'], 'platformGame');
  final game = requireObject(platformGame['game'], 'platformGame.game');
  final platform = requireObject(
    platformGame['platform'],
    'platformGame.platform',
  );
  final suppliedBy = requireObject(json['suppliedBy'], 'suppliedBy');
  final attendee = suppliedBy['attendee'];
  final thumbnail = game['thumbnail'] as String?;
  return LineupGame(
    id: json['id'] as String,
    occurrenceId: json['occurrenceId'] as String?,
    platformGameId: json['platformGameId'] as String,
    gameId: game['id'] as String,
    title: game['title'] as String,
    subtitle: game['subtitle'] as String?,
    platformName: platform['name'] as String,
    thumbnail: thumbnail == null || thumbnail.isEmpty ? null : thumbnail,
    role: ScheduledGameRole.fromWire(json['role'] as String),
    sortOrder: json['sortOrder'] as int,
    notes: json['notes'] as String?,
    maxPlayTime: json['maxPlayTime'] as int?,
    nominationId: json['nominationId'] as String?,
    addedById: json['addedById'] as String?,
    suppliedById: suppliedBy['id'] as String,
    supplierAttendeeId: suppliedBy['attendeeId'] as String,
    supplierName: attendee == null
        ? null
        : _attendeeName(requireObject(attendee, 'suppliedBy.attendee')),
  );
}

/// The name to show for an attendee summary, as [EventAttendee.name] decides
/// it.
String? _attendeeName(Map<String, dynamic> json) {
  final user = readUserProjection(json['user'], row: 'attendee');
  return personName(
        displayName: user.displayName,
        username: user.username,
      ) ??
      personName(username: json['guestName'] as String?);
}

EventNominationVote _mapNominationVote(Map<String, dynamic> json) =>
    EventNominationVote(
      id: json['id'] as String,
      attendeeId: json['attendeeId'] as String,
      voteType: VoteType.fromWire(json['voteType'] as String),
      eligible: json['eligible'] as bool,
      comment: json['comment'] as String?,
    );

/// A resolve's `resolution` (#518). Its status goes through
/// [NominationStatus.fromWire], so a name this client does not know is
/// [NominationStatus.unknown].
NominationResolution mapResolution(Map<String, dynamic> json) {
  final tally = requireObject(json['tally'], 'resolution.tally');
  return NominationResolution(
    status: NominationStatus.fromWire(json['status'] as String),
    forCount: tally['forCount'] as int,
    againstCount: tally['againstCount'] as int,
    interestedCount: tally['interestedCount'] as int,
    totalVotes: tally['totalVotes'] as int,
    quorumMet: json['quorumMet'] as bool,
    thresholdMet: json['thresholdMet'] as bool,
    eligibleVoterCount: json['eligibleVoterCount'] as int,
  );
}

Event mapEvent(Map<String, dynamic> json) => Event(
  id: json['id'] as String,
  title: json['title'] as String,
  createdById: json['createdById'] as String,
  householdId: json['householdId'] as String?,
  description: json['description'] as String?,
  image: json['image'] as String?,
  location: json['location'] as String?,
  url: json['url'] as String?,
  type: EventType.fromWire(json['type'] as String),
  reach: Reach.fromWire(json['reach'] as String),
  status: EventStatus.fromWire(json['status'] as String),
  schedulingMode: EventSchedulingMode.fromWire(
    json['schedulingMode'] as String,
  ),
  cancelReason: json['cancelReason'] as String?,
  cancelledAt: dateOrNull(json['cancelledAt']),
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

List<EventOccurrence> _mapOccurrences(Object? raw) =>
    mapObjects(raw, field: 'occurrences', item: mapOccurrence);

/// Maps one result of a batch offer (#851).
///
/// `added` and `alreadyOffered` are offered. Their `entry` row goes unread:
/// the caller reads the pool again after a run, and a row this client
/// can't read would otherwise fail a batch the server has written. Any
/// other outcome is a refusal, so an outcome a newer server adds is not a
/// failure of the whole answer. Its reason is [GameOfferRefusal.unknown]
/// when missing or not known, and its message is empty when missing.
GameOfferResult mapGameOfferResult(Map<String, dynamic> json) {
  final collectionId = json['collectionId'] as String;
  final outcome = json['outcome'];
  if (outcome == 'added' || outcome == 'alreadyOffered') {
    return GameOfferResult.offered(
      collectionId: collectionId,
      alreadyOffered: outcome == 'alreadyOffered',
    );
  }
  final reason = json['reason'];
  final message = json['message'];
  return GameOfferResult.refused(
    collectionId: collectionId,
    reason: reason is String
        ? GameOfferRefusal.fromWire(reason)
        : GameOfferRefusal.unknown,
    message: message is String ? message : '',
  );
}

EventOccurrence mapOccurrence(Map<String, dynamic> json) => EventOccurrence(
  id: json['id'] as String,
  eventId: json['eventId'] as String,
  label: json['label'] as String?,
  startDate: dateOrNull(json['startDate']),
  endDate: dateOrNull(json['endDate']),
  location: json['location'] as String?,
  status: OccurrenceStatus.fromWire(json['status'] as String),
  sortOrder: json['sortOrder'] as int,
  confirmedAt: dateOrNull(json['confirmedAt']),
  declinedAt: dateOrNull(json['declinedAt']),
  cancelledAt: dateOrNull(json['cancelledAt']),
  cancelReason: json['cancelReason'] as String?,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

/// Maps the embedded policy. Null is an event with none, or a detail read by
/// a caller who may not read it (backend#560); either way the model carries
/// no policy.
///
/// [served] is the backend's policy view, which the detail read, the create
/// and the policy update answer with: its three rule lists are always there,
/// never null, so a missing or null one is a contract break rather than a
/// read that didn't carry it, which would keep the cached lists (#1009). A
/// list row's policy is the bare row, without them, and reads as not
/// carried.
EventPolicy? mapPolicy(Object? raw, {required bool served}) {
  if (raw == null) return null;
  if (raw is! Map<String, dynamic>) {
    throw FormatException(
      'event "policy" is ${raw.runtimeType}, expected an object or null',
    );
  }
  return EventPolicy(
    id: raw['id'] as String,
    eventId: raw['eventId'] as String,
    allowMemberInvites: raw['allowMemberInvites'] as bool,
    allowGuestInvites: raw['allowGuestInvites'] as bool,
    maxAttendees: raw['maxAttendees'] as int?,
    restrictToGameCategories: raw['restrictToGameCategories'] as bool,
    requireHostApprovalToJoin: raw['requireHostApprovalToJoin'] as bool,
    allowSpectators: raw['allowSpectators'] as bool,
    maxTotalParticipants: raw['maxTotalParticipants'] as int?,
    strictCapacity: raw['strictCapacity'] as bool,
    gameAdditionMode: GameAdditionMode.fromWire(
      raw['gameAdditionMode'] as String,
    ),
    restrictToAttendeePool: raw['restrictToAttendeePool'] as bool,
    fillerMaxPlayTime: raw['fillerMaxPlayTime'] as int?,
    voteThresholdType: VoteThresholdType.fromWire(
      raw['voteThresholdType'] as String,
    ),
    voteThresholdValue: raw['voteThresholdValue'] as int?,
    voteQuorumType: VoteQuorumType.fromWire(raw['voteQuorumType'] as String),
    voteQuorumValue: raw['voteQuorumValue'] as int?,
    voteEligibility: VoteEligibility.fromWire(
      raw['voteEligibility'] as String,
    ),
    interestedWeight: InterestedWeight.fromWire(
      raw['interestedWeight'] as String,
    ),
    votingWindowHours: raw['votingWindowHours'] as int?,
    allowedPlatformTypes: _policyList(
      raw,
      'allowedPlatformTypes',
      served: served,
    )?.map(PlatformType.fromWire).toList(growable: false),
    allowedPlatformIds: _policyList(
      raw,
      'allowedPlatformIds',
      served: served,
    ),
    allowedCategoryIds: _policyList(
      raw,
      'allowedCategoryIds',
      served: served,
    ),
    // A column of the row, so every read that serves a policy carries it,
    // the list read's included.
    occurrenceOverrideScope: OccurrenceOverrideScope.fromWire(
      raw['occurrenceOverrideScope'] as String,
    ),
    createdAt: DateTime.parse(raw['createdAt'] as String),
    updatedAt: DateTime.parse(raw['updatedAt'] as String),
  );
}

/// Maps one date's own rules (#1009). The nullable fields are overrides, and
/// null means the event's. The lists and `*Unrestricted` flags are never null
/// on the wire, so a missing or mistyped one throws.
EventOccurrencePolicy _mapOccurrencePolicy(
  Map<String, dynamic> json,
) => EventOccurrencePolicy(
  id: json['id'] as String,
  occurrenceId: json['occurrenceId'] as String,
  allowedCategoryIds: _stringList(
    json['allowedCategoryIds'],
    field: 'allowedCategoryIds',
  ),
  allowedPlatformIds: _stringList(
    json['allowedPlatformIds'],
    field: 'allowedPlatformIds',
  ),
  allowedPlatformTypes: _stringList(
    json['allowedPlatformTypes'],
    field: 'allowedPlatformTypes',
  ).map(PlatformType.fromWire).toList(growable: false),
  platformTypesUnrestricted: json['platformTypesUnrestricted'] as bool,
  platformsUnrestricted: json['platformsUnrestricted'] as bool,
  capacityUnrestricted: json['capacityUnrestricted'] as bool,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  restrictToGameCategories: json['restrictToGameCategories'] as bool?,
  strictCapacity: json['strictCapacity'] as bool?,
  requireHostApprovalToJoin: json['requireHostApprovalToJoin'] as bool?,
  allowSpectators: json['allowSpectators'] as bool?,
  restrictToAttendeePool: json['restrictToAttendeePool'] as bool?,
  maxAttendees: json['maxAttendees'] as int?,
  maxTotalParticipants: json['maxTotalParticipants'] as int?,
  fillerMaxPlayTime: json['fillerMaxPlayTime'] as int?,
  voteThresholdValue: json['voteThresholdValue'] as int?,
  voteQuorumValue: json['voteQuorumValue'] as int?,
  votingWindowHours: json['votingWindowHours'] as int?,
  gameAdditionMode: _wireOrNull(
    json['gameAdditionMode'],
    GameAdditionMode.fromWire,
  ),
  voteThresholdType: _wireOrNull(
    json['voteThresholdType'],
    VoteThresholdType.fromWire,
  ),
  voteQuorumType: _wireOrNull(
    json['voteQuorumType'],
    VoteQuorumType.fromWire,
  ),
  voteEligibility: _wireOrNull(
    json['voteEligibility'],
    VoteEligibility.fromWire,
  ),
  interestedWeight: _wireOrNull(
    json['interestedWeight'],
    InterestedWeight.fromWire,
  ),
);

T? _wireOrNull<T>(Object? value, T Function(String) fromWire) =>
    value == null ? null : fromWire(value as String);

EventAttendee mapAttendee(Map<String, dynamic> json) {
  final user = readUserProjection(json['user'], row: 'attendee');
  return EventAttendee(
    id: json['id'] as String,
    eventId: json['eventId'] as String,
    userId: json['userId'] as String?,
    guestName: json['guestName'] as String?,
    username: user.username,
    displayName: user.displayName,
    avatarUrl: user.avatarUrl,
    notes: json['notes'] as String?,
    status: EventParticipationStatus.fromWire(json['status'] as String),
    role: _mapRole(json['role']),
    rsvpDate: dateOrNull(json['rsvpDate']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

/// Reads the caller's own answer off a list or detail row, `{ attendeeId,
/// status, role, rsvpDate }`.
///
/// Null, or a missing key, is a caller with no attendee row, and so is every
/// browse row. `role` here is the role's name, a string, not the roster's
/// nested projection that [_mapRole] reads. A shape that is wrong is a
/// contract breach and throws, rather than passing for "no answer".
EventAttendance? _mapAttendance(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map<String, dynamic>) {
    throw FormatException(
      'event "attendance" is ${raw.runtimeType}, expected an object or null',
    );
  }
  final role = raw['role'];
  if (role != null && role is! String) {
    throw FormatException(
      'attendance "role" is ${role.runtimeType}, '
      'expected a role name or null',
    );
  }
  return EventAttendance(
    attendeeId: raw['attendeeId'] as String,
    status: EventParticipationStatus.fromWire(raw['status'] as String),
    role: role == null ? null : EventRole.fromWire(role as String),
    rsvpDate: dateOrNull(raw['rsvpDate']),
  );
}

/// The attendee's role, read by [readRoleName]: null for an attendee with
/// no role binding, and a [FormatException] for a projection whose shape is
/// wrong.
EventRole? _mapRole(Object? projection) {
  final name = readRoleName(projection, row: 'attendee');
  return name == null ? null : EventRole.fromWire(name);
}

AvailabilityVote mapVote(Map<String, dynamic> json) => AvailabilityVote(
  id: json['id'] as String,
  occurrenceId: json['occurrenceId'] as String,
  attendeeId: json['attendeeId'] as String,
  response: AvailabilityResponse.fromWire(json['response'] as String),
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

/// Maps the summary's dates. Its `attendees` and `eligibleVoters` are not
/// read (backend#759), and neither is anything a date carries beyond its
/// tallies and voters.
AvailabilitySummary mapSummary(Map<String, dynamic> json) =>
    AvailabilitySummary(
      occurrences: mapObjects(
        json['occurrences'],
        field: 'occurrences',
        item: _mapOccurrenceAvailability,
      ),
      rosterVisible: switch (json['attendees']) {
        {'total': final int total} => total > 0,
        _ => true,
      },
    );

OccurrenceAvailability _mapOccurrenceAvailability(
  Map<String, dynamic> json,
) => OccurrenceAvailability(
  occurrenceId: json['occurrenceId'] as String,
  available: json['available'] as int,
  maybe: json['maybe'] as int,
  unavailable: json['unavailable'] as int,
  voters: mapObjects(json['voters'], field: 'voters', item: _mapVoter),
);

AvailabilityVoter _mapVoter(Map<String, dynamic> json) => AvailabilityVoter(
  attendeeId: json['attendeeId'] as String,
  response: AvailabilityResponse.fromWire(json['response'] as String),
  eligible: json['eligible'] as bool,
);

/// An offered game's medium, or null when [raw] is not a medium this client
/// knows: absent, null, not a string, or a name a newer server added
/// (#516).
///
/// Lenient where the user's own collection rows are strict: the pool is
/// other people's rows, and one unknown medium must not fail every event's
/// pool read. Only `fromWire`'s own refusal of a name is caught.
GameMedium? _offeredMediumOrNull(Object? raw) {
  if (raw is! String) return null;
  try {
    return GameMedium.fromWire(raw);
  } on FormatException {
    return null;
  }
}

/// Maps one offered game (#516, #851), a row of the pool read or an add's
/// `entry`: the row's ids, its collection entry's id and medium, the
/// platform game and game under it, and what the entry supplies.
///
/// - The players and play time are the platform game's own pair when either
///   of its two is set, otherwise the game's pair, as a collection row's
///   are (#715).
/// - The thumbnail is the platform game's own picture when it has one,
///   otherwise the game's: each one's thumbnail, else its full image, as a
///   collection row's is (#709). An empty string is none.
/// - A medium this client does not know is none (see
///   [_offeredMediumOrNull]).
/// - A content type or platform type that is missing is null, and a name
///   this client does not know is that type's `unknown`.
/// - Each `supplies` count is null where the server says null, for a viewer
///   who can't read that kind of row. A row with no `supplies` reads both
///   as null: not known, which is not none.
///
/// The row's `attendee` and the game's `baseGames` are not read.
OfferedGame mapOfferedGame(Map<String, dynamic> json) {
  final collection = requireObject(json['collection'], 'collection');
  final platformGame = requireObject(
    collection['platformGame'],
    'collection.platformGame',
  );
  final game = requireObject(
    platformGame['game'],
    'collection.platformGame.game',
  );
  final platform = requireObject(
    platformGame['platform'],
    'collection.platformGame.platform',
  );
  final ownPlayers =
      platformGame['minPlayers'] != null || platformGame['maxPlayers'] != null;
  final ownPlayTime =
      platformGame['minPlayTime'] != null ||
      platformGame['maxPlayTime'] != null;
  final players = ownPlayers ? platformGame : game;
  final playTime = ownPlayTime ? platformGame : game;
  final supplies = json['supplies'];
  final supplied = supplies is Map<String, dynamic>
      ? supplies
      : const <String, dynamic>{};
  final contentType = game['contentType'];
  final platformType = platform['platformType'];
  return OfferedGame(
    id: json['id'] as String,
    attendeeId: json['attendeeId'] as String,
    collectionId: collection['id'] as String,
    platformGameId: platformGame['id'] as String,
    gameId: game['id'] as String,
    title: game['title'] as String,
    subtitle: game['subtitle'] as String?,
    platformName: platform['name'] as String,
    platformType: platformType is String
        ? PlatformType.fromWire(platformType)
        : null,
    thumbnail:
        nonEmptyString(platformGame['thumbnail']) ??
        nonEmptyString(platformGame['image']) ??
        nonEmptyString(game['thumbnail']) ??
        nonEmptyString(game['image']),
    medium: _offeredMediumOrNull(collection['medium']),
    contentType: contentType is String
        ? ContentType.fromWire(contentType)
        : null,
    publishYear: game['publishYear'] as int?,
    minPlayers: players['minPlayers'] as int?,
    maxPlayers: players['maxPlayers'] as int?,
    minPlayTime: playTime['minPlayTime'] as int?,
    maxPlayTime: playTime['maxPlayTime'] as int?,
    suppliedNominations: supplied['nominations'] as int?,
    suppliedLineup: supplied['lineup'] as int?,
  );
}

/// Maps each object in the list [raw]. A list that is missing or of the
/// wrong type throws, because reading it as empty would pass off a payload
/// this client failed to read as one with none of them. [field] names it in
/// the error.
List<T> mapObjects<T>(
  Object? raw, {
  required String field,
  required T Function(Map<String, dynamic> json) item,
}) {
  if (raw is! List) {
    throw FormatException(
      raw == null
          ? '"$field" is missing, expected a list'
          : '"$field" is ${raw.runtimeType}, expected a list',
    );
  }
  return raw
      .map((entry) {
        if (entry is! Map<String, dynamic>) {
          throw FormatException(
            'an entry in "$field" is ${entry.runtimeType}, expected an '
            'object',
          );
        }
        return item(entry);
      })
      .toList(growable: false);
}

/// One of a policy's rule lists, as [mapPolicy] reads it: required when
/// the policy is [served] as the view, null when a list row's bare policy
/// leaves it out. Present, it must be a list of strings, or the payload is
/// a contract break rather than an empty list.
List<String>? _policyList(
  Map<String, dynamic> policy,
  String field, {
  required bool served,
}) => served || policy[field] != null
    ? _stringList(policy[field], field: field)
    : null;

/// Reads [raw], the payload's [field], as a list of strings, which it
/// must carry: absent, not a list, or holding anything but strings, it is
/// a contract break, a [FormatException] naming [field].
List<String> _stringList(Object? raw, {required String field}) {
  if (raw is! List) {
    throw FormatException(
      raw == null
          ? '"$field" is missing, expected a list'
          : '"$field" is ${raw.runtimeType}, expected a list',
    );
  }
  return raw
      .map((entry) {
        if (entry is! String) {
          throw FormatException(
            'an entry in "$field" is ${entry.runtimeType}, expected a '
            'string',
          );
        }
        return entry;
      })
      .toList(growable: false);
}

// ── Request body ────────────────────────────────────────────────────

/// The create's body. A field the draft leaves null is left out, and so is an
/// empty list, so the server's defaults apply.
///
/// Runs after [EventDraft.checkSendable], which is what keeps `toWire` from
/// throwing on an `unknown` value.
Map<String, Object?> eventCreateBody(
  EventDraft draft,
  String clientRequestId,
) => {
  'title': draft.title,
  // Sent as given: the server trims it before it stores or matches it.
  'clientRequestId': clientRequestId,
  'schedulingMode': draft.schedulingMode.toWire(),
  'householdId': ?draft.householdId,
  'description': ?draft.description,
  'location': ?draft.location,
  'url': ?draft.url,
  'type': ?draft.type?.toWire(),
  'reach': ?draft.reach?.toWire(),
  if (draft.occurrences.isNotEmpty)
    'occurrences': [
      for (final (index, occurrence) in draft.occurrences.indexed)
        {
          'label': ?occurrence.label,
          'startDate': ?occurrence.startDate?.toUtc().toIso8601String(),
          'endDate': ?occurrence.endDate?.toUtc().toIso8601String(),
          'location': ?occurrence.location,
          'sortOrder': index,
        },
    ],
  if (draft.policy case final policy?)
    'policy': {
      'gameAdditionMode': ?policy.gameAdditionMode?.toWire(),
      'voteThresholdType': ?policy.voteThresholdType?.toWire(),
      'voteThresholdValue': ?policy.voteThresholdValue,
      'voteQuorumType': ?policy.voteQuorumType?.toWire(),
      'voteQuorumValue': ?policy.voteQuorumValue,
      'votingWindowHours': ?policy.votingWindowHours,
    },
  if (draft.inviteUserIds.isNotEmpty) 'inviteUserIds': draft.inviteUserIds,
};
