import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('Visibility', () {
    group('toWire', () {
      test('every value maps to its @JsonValue PascalCase string', () {
        const expectations = <Visibility, String>{
          Visibility.friends: 'Friends',
          Visibility.friendsOfFriends: 'FriendsOfFriends',
          Visibility.friendsOfHouseholds: 'FriendsOfHouseholds',
          Visibility.household: 'Household',
          Visibility.private: 'Private',
          Visibility.public: 'Public',
        };

        // Sanity: the table covers every enum variant. If a new
        // variant is added without an entry here, the test fails
        // with a length mismatch rather than silently skipping the
        // new value.
        expect(expectations.keys.toSet(), equals(Visibility.values.toSet()));

        for (final entry in expectations.entries) {
          expect(
            entry.key.toWire(),
            equals(entry.value),
            reason:
                'Visibility.${entry.key.name}.toWire() should be "${entry.value}"',
          );
        }
      });
    });

    group('fromWire', () {
      test('every wire string maps back to its Visibility variant', () {
        const expectations = <String, Visibility>{
          'Friends': Visibility.friends,
          'FriendsOfFriends': Visibility.friendsOfFriends,
          'FriendsOfHouseholds': Visibility.friendsOfHouseholds,
          'Household': Visibility.household,
          'Private': Visibility.private,
          'Public': Visibility.public,
        };

        expect(expectations.values.toSet(), equals(Visibility.values.toSet()));

        for (final entry in expectations.entries) {
          expect(
            Visibility.fromWire(entry.key),
            equals(entry.value),
            reason:
                'Visibility.fromWire("${entry.key}") should be Visibility.${entry.value.name}',
          );
        }
      });

      test(
        'round-trip: every value survives Visibility → wire → Visibility',
        () {
          for (final value in Visibility.values) {
            expect(
              Visibility.fromWire(value.toWire()),
              equals(value),
              reason: 'Round-trip failed for Visibility.${value.name}',
            );
          }
        },
      );

      test('fromWire throws StateError on an unrecognised wire value', () {
        // Visibility's design is deliberately strict: there's no
        // `unknown` fallback variant (unlike ContentType,
        // TimeMeasure, GameMedium, HouseholdRole). An unrecognised
        // wire string represents either DB corruption or a
        // server-side enum extension this client hasn't been
        // updated for, and both must surface rather than be
        // silently coerced into one of the existing variants.
        //
        // A future regression that adds an `unknown` fallback or
        // changes the default arm to a silent coercion would fail
        // this assertion.
        expect(
          () => Visibility.fromWire('NotARealVisibility'),
          throwsStateError,
        );
      });
    });
  });
}
