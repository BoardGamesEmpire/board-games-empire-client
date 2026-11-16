import 'package:analytics/analytics.dart';
import 'package:models/domain.dart';
import 'package:test/test.dart';

import 'support/catalog_samples.dart';

void main() {
  test('CollectionGameAdded carries the id and medium', () {
    final e = CollectionGameAdded(
      platformGameId: 'tz4a98xxat96iws9zmbrgj3a',
      medium: GameMedium.digital,
    );
    expect(e.name, 'collection.game_added');
    expect(e.properties.keys, ['platformGameId', 'medium']);
    expect(
      e.properties['platformGameId']!.wireValue,
      'tz4a98xxat96iws9zmbrgj3a',
    );
    expect(e.properties['medium']!.wireValue, 'digital');
  });

  test('a title passed as a game id throws at construction', () {
    expect(
      () => CollectionGameAdded(
        platformGameId: 'Catan',
        medium: GameMedium.physical,
      ),
      throwsArgumentError,
    );
  });

  test('EventCreated carries type and scheduling mode tokens', () {
    final e = EventCreated(
      type: EventType.strategyNight,
      schedulingMode: EventSchedulingMode.poll,
    );
    expect(e.name, 'event.created');
    expect(
      {for (final p in e.properties.entries) p.key: p.value.wireValue},
      {'type': 'strategyNight', 'schedulingMode': 'poll'},
    );
  });

  test('property-less events send an empty map', () {
    expect(const HouseholdCreated().properties, isEmpty);
    expect(const EventGameNominated().properties, isEmpty);
  });

  group('every catalog event', () {
    for (final e in catalogSamples) {
      group(e.name, () {
        test('is named area.verb_past', () {
          expect(
            e.name,
            matches(RegExp(r'^[a-z]+(_[a-z]+)*\.[a-z]+(_[a-z]+)*$')),
          );
        });

        test('sits in the area its class belongs to', () {
          expect(e.name, startsWith('${areaOf(e)}.'));
        });

        test('uses camelCase property keys', () {
          for (final k in e.properties.keys) {
            expect(k, matches(RegExp(r'^[a-z][a-zA-Z0-9]*$')));
          }
        });

        test('refuses mutation of its properties', () {
          expect(
            () => e.properties['x'] = AnalyticsInt(1),
            throwsUnsupportedError,
          );
        });
      });
    }

    test('names are unique', () {
      final names = catalogSamples.map((e) => e.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });
  });
}
