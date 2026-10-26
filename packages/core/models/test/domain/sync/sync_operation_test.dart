import 'package:test/test.dart';
import 'package:models/domain.dart';

void main() {
  group('CreateHouseholdOperation', () {
    test('type discriminator is create_household', () {
      expect(CreateHouseholdOperation.type, equals('create_household'));
    });

    test('toJson omits null optional fields', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
      );

      final json = op.toJson();
      expect(json['type'], equals('create_household'));
      expect(json['local_id'], equals('hh_local_1'));
      expect(json['name'], equals('Game Night HQ'));
      expect(json.containsKey('description'), isFalse);
      expect(json.containsKey('image'), isFalse);
      expect(json.containsKey('language'), isFalse);
      expect(json.containsKey('visibility'), isFalse);
    });

    test('toJson includes optional fields when set', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
        description: 'Where we play',
        image: 'https://example.test/hh.png',
        language: 'pt-BR',
        visibility: 'Friends',
      );

      final json = op.toJson();
      expect(json['description'], equals('Where we play'));
      expect(json['image'], equals('https://example.test/hh.png'));
      expect(json['language'], equals('pt-BR'));
      expect(json['visibility'], equals('Friends'));
    });

    test('round-trips through fromJson preserving all fields', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
        description: 'Where we play',
        image: 'https://example.test/hh.png',
        language: 'pt-BR',
        visibility: 'Friends',
      );

      final round = CreateHouseholdOperation.fromJson(op.toJson());
      expect(round.localId, equals('hh_local_1'));
      expect(round.name, equals('Game Night HQ'));
      expect(round.description, equals('Where we play'));
      expect(round.image, equals('https://example.test/hh.png'));
      expect(round.language, equals('pt-BR'));
      expect(round.visibility, equals('Friends'));
    });

    test('optional fields survive a round-trip as null', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
      );

      final round = CreateHouseholdOperation.fromJson(op.toJson());
      expect(round.description, isNull);
      expect(round.image, isNull);
      expect(round.language, isNull);
      expect(round.visibility, isNull);
    });

    test('serialized string round-trips via SyncOperation.deserialize', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
      );

      final decoded = SyncOperation.deserialize(op.serialized);
      expect(decoded, isA<CreateHouseholdOperation>());
      final typed = decoded as CreateHouseholdOperation;
      expect(typed.localId, equals('hh_local_1'));
      expect(typed.name, equals('Game Night HQ'));
    });
  });

  group('CreateEventOperation', () {
    // Every field set, each to a value no other field holds, so a field read
    // back into the wrong place shows.
    final full = CreateEventOperation(
      localId: 'ev_local_1',
      draft: EventDraft(
        title: 'Game night',
        householdId: 'hh-1',
        description: 'Bring snacks.',
        location: 'Kitchen table',
        url: 'https://example.test/events/1',
        type: EventType.strategyNight,
        reach: Reach.friendsOfFriends,
        schedulingMode: EventSchedulingMode.poll,
        occurrences: [
          EventOccurrenceDraft(
            label: 'First Friday',
            startDate: DateTime.utc(2026, 11, 6, 18),
            endDate: DateTime.utc(2026, 11, 6, 22, 30),
            location: 'Back room',
          ),
          const EventOccurrenceDraft(),
        ],
        policy: const EventPolicyDraft(
          gameAdditionMode: GameAdditionMode.requiresVote,
          voteThresholdType: VoteThresholdType.supermajority,
          voteThresholdValue: 66,
          voteQuorumType: VoteQuorumType.fixedCount,
          voteQuorumValue: 3,
          votingWindowHours: 48,
        ),
        inviteUserIds: const ['user-b', 'user-c'],
      ),
    );

    const titleOnly = CreateEventOperation(
      localId: 'ev_local_2',
      draft: EventDraft(title: 'Game night'),
    );

    test('type discriminator is create_event', () {
      expect(CreateEventOperation.type, 'create_event');
    });

    test('an event create round-trips through JSON, with every field '
        'set', () {
      final round = SyncOperation.deserialize(full.serialized);

      expect(round, isA<CreateEventOperation>());
      final create = round as CreateEventOperation;
      expect(create.localId, 'ev_local_1');
      expect(create.draft, full.draft);
    });

    test('an event create round-trips through JSON, with only the '
        'title', () {
      final round = SyncOperation.deserialize(titleOnly.serialized);

      expect(round, isA<CreateEventOperation>());
      final create = round as CreateEventOperation;
      expect(create.localId, 'ev_local_2');
      expect(create.draft, titleOnly.draft);
    });

    test('its JSON names enums by wire name and dates in UTC', () {
      expect(full.toJson(), {
        'type': 'create_event',
        'local_id': 'ev_local_1',
        'title': 'Game night',
        'household_id': 'hh-1',
        'description': 'Bring snacks.',
        'location': 'Kitchen table',
        'url': 'https://example.test/events/1',
        'event_type': 'StrategyNight',
        'reach': 'FriendsOfFriends',
        'scheduling_mode': 'Poll',
        'occurrences': [
          {
            'label': 'First Friday',
            'start_date': '2026-11-06T18:00:00.000Z',
            'end_date': '2026-11-06T22:30:00.000Z',
            'location': 'Back room',
          },
          <String, dynamic>{},
        ],
        'policy': {
          'game_addition_mode': 'RequiresVote',
          'vote_threshold_type': 'Supermajority',
          'vote_threshold_value': 66,
          'vote_quorum_type': 'FixedCount',
          'vote_quorum_value': 3,
          'voting_window_hours': 48,
        },
        'invite_user_ids': ['user-b', 'user-c'],
      });
    });

    test('its JSON leaves out what the draft leaves unset', () {
      expect(titleOnly.toJson(), {
        'type': 'create_event',
        'local_id': 'ev_local_2',
        'title': 'Game night',
        'scheduling_mode': 'Fixed',
        'occurrences': <Object>[],
        'invite_user_ids': <Object>[],
      });
    });

    test('a date given in local time goes out in UTC', () {
      final local = DateTime(2026, 11, 6, 18);
      final op = CreateEventOperation(
        localId: 'ev_local_3',
        draft: EventDraft(
          title: 'Game night',
          occurrences: [EventOccurrenceDraft(startDate: local)],
        ),
      );

      final occurrences = op.toJson()['occurrences'] as List<Object?>;
      final startDate = (occurrences.single! as Map)['start_date'] as String;
      expect(startDate, endsWith('Z'));
      expect(DateTime.parse(startDate), local.toUtc());
    });

    test('an event create with an unknown enum name fails to decode with a '
        'FormatException', () {
      // An `unknown` read back would be a value with no wire name, which the
      // send could not put on the wire. Failing the decode lets the sender
      // count the entry as an op it can't read.
      final json = full.toJson();
      final policy = json['policy'] as Map<String, dynamic>;
      final unreadable = <String, Map<String, dynamic>>{
        'event_type': {...json, 'event_type': 'Picnic'},
        'reach': {...json, 'reach': 'Galaxy'},
        'scheduling_mode': {...json, 'scheduling_mode': 'Recurring'},
        'game_addition_mode': {
          ...json,
          'policy': {...policy, 'game_addition_mode': 'Lottery'},
        },
        'vote_threshold_type': {
          ...json,
          'policy': {...policy, 'vote_threshold_type': 'Plurality'},
        },
        'vote_quorum_type': {
          ...json,
          'policy': {...policy, 'vote_quorum_type': 'Everyone'},
        },
        // The name the cache stores for a value it couldn't read is no
        // wire name either.
        'Unknown': {...json, 'reach': 'Unknown'},
      };

      for (final MapEntry(key: field, value: payload) in unreadable.entries) {
        expect(
          () => SyncOperation.fromJson(payload),
          throwsFormatException,
          reason: field,
        );
      }
    });

    test('localId is carried, not re-minted, across a round trip', () {
      final once = SyncOperation.deserialize(full.serialized);
      final twice = SyncOperation.deserialize(once.serialized);

      expect((twice as CreateEventOperation).localId, full.localId);
    });
  });

  group('AddToCollectionOperation', () {
    const add = AddToCollectionOperation(
      localId: 'col_1',
      platformGameId: 'pg_1',
      medium: 'Physical',
      quantity: 1,
    );

    test('round-trips whether the add raised a quantity (#190)', () {
      const raise = AddToCollectionOperation(
        localId: 'col_1',
        platformGameId: 'pg_1',
        medium: 'Physical',
        quantity: 2,
        raised: true,
      );

      final round = AddToCollectionOperation.fromJson(raise.toJson());

      expect(round.raised, isTrue);
    });

    test('leaves the raise flag out of any other add, and reads its absence '
        'as null', () {
      expect(add.toJson().containsKey('raised'), isFalse);
      expect(AddToCollectionOperation.fromJson(add.toJson()).raised, isNull);
    });
  });

  group('SyncOperation.fromJson dispatch', () {
    test('dispatches create_household to CreateHouseholdOperation', () {
      final op = SyncOperation.fromJson(const {
        'type': 'create_household',
        'local_id': 'hh_local_1',
        'name': 'Game Night HQ',
      });
      expect(op, isA<CreateHouseholdOperation>());
    });

    test('dispatches create_event to CreateEventOperation', () {
      final op = SyncOperation.fromJson(const {
        'type': 'create_event',
        'local_id': 'ev_local_1',
        'title': 'Game night',
        'scheduling_mode': 'Fixed',
        'occurrences': <Object>[],
        'invite_user_ids': <Object>[],
      });
      expect(op, isA<CreateEventOperation>());
    });

    test('still dispatches the existing collection ops', () {
      final add = SyncOperation.fromJson(const {
        'type': 'add_to_collection',
        'local_id': 'col_1',
        'platform_game_id': 'pg_1',
        'medium': 'Physical',
        'quantity': 1,
      });
      expect(add, isA<AddToCollectionOperation>());
    });

    test('decodes an update_collection that still carries play history '
        'and does not carry it forward', () {
      // The update surface once accepted playCount / lastPlayed, which the
      // server owns and rejects (#258). A payload queued in that shape must
      // still decode, and must not put those fields back on the wire.
      final op = SyncOperation.fromJson(const {
        'type': 'update_collection',
        'collection_id': 'col_1',
        'rating': 7,
        'play_count': 3,
        'last_played': '2025-06-01T00:00:00.000Z',
      });

      expect(op, isA<UpdateCollectionOperation>());
      final update = op as UpdateCollectionOperation;
      expect(update.collectionId, equals('col_1'));
      expect(update.rating, equals(7));
      expect(update.toJson(), {
        'type': 'update_collection',
        'collection_id': 'col_1',
        'rating': 7,
      });
    });

    test('throws FormatException on an unknown type', () {
      expect(
        () => SyncOperation.fromJson(const {'type': 'not_a_real_op'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
