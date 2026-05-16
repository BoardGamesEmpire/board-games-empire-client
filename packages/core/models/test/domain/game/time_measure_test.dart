import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

Game _makeGame({required TimeMeasure measure}) {
  final now = DateTime.parse('2024-01-15T10:30:00Z');
  return Game(
    id: 'game_1',
    title: 'Test Game',
    minPlayTime: 30,
    minPlayTimeMeasure: measure,
    maxPlayTime: 60,
    maxPlayTimeMeasure: measure,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('TimeMeasure', () {
    test('every Dart value round-trips through Game time fields', () {
      for (final value in TimeMeasure.values) {
        final game = _makeGame(measure: value);
        final round = Game.fromJson(game.toJson());
        expect(round.minPlayTimeMeasure, equals(value));
        expect(round.maxPlayTimeMeasure, equals(value));
      }
    });

    test('wire format is PascalCase', () {
      const expectations = <TimeMeasure, String>{
        TimeMeasure.minutes: 'Minutes',
        TimeMeasure.hours: 'Hours',
        TimeMeasure.days: 'Days',
        TimeMeasure.weeks: 'Weeks',
        TimeMeasure.months: 'Months',
        TimeMeasure.years: 'Years',
      };

      for (final entry in expectations.entries) {
        final json = _makeGame(measure: entry.key).toJson();
        expect(json['minPlayTimeMeasure'], equals(entry.value));
        expect(json['maxPlayTimeMeasure'], equals(entry.value));
      }
    });

    test('every Prisma TimeMeasure value has a Dart binding', () {
      const serverValues = <String>[
        'Minutes',
        'Hours',
        'Days',
        'Weeks',
        'Months',
        'Years',
      ];
      for (final wireValue in serverValues) {
        final json = _makeGame(measure: TimeMeasure.minutes).toJson();
        json['minPlayTimeMeasure'] = wireValue;
        json['maxPlayTimeMeasure'] = wireValue;
        expect(() => Game.fromJson(json), returnsNormally);
      }
    });

    test('static fromJson/toJson helpers agree with @JsonValue mappings', () {
      for (final value in TimeMeasure.values) {
        final viaJsonValue =
            _makeGame(measure: value).toJson()['minPlayTimeMeasure'] as String;
        expect(value.toJson(), equals(viaJsonValue));
        expect(TimeMeasure.fromJson(viaJsonValue), equals(value));
      }
    });
  });
}
