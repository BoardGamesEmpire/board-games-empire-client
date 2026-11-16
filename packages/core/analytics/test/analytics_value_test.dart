import 'package:analytics/analytics.dart';
import 'package:test/test.dart';

enum _Colour { red, green, unknown }

enum _Other { red }

void main() {
  group('AnalyticsInt / AnalyticsBool', () {
    test('carry their value as the wire value', () {
      expect(AnalyticsInt(3).wireValue, 3);
      expect(AnalyticsInt(3).kind, AnalyticsValueKind.integer);
      expect(const AnalyticsBool(true).wireValue, true);
      expect(const AnalyticsBool(true).kind, AnalyticsValueKind.boolean);
    });
  });

  group('AnalyticsInt', () {
    test('accepts both ends of the safe-integer range', () {
      expect(
        AnalyticsInt(AnalyticsInt.maxSafe).wireValue,
        9007199254740991,
      );
      expect(
        AnalyticsInt(-AnalyticsInt.maxSafe).wireValue,
        -9007199254740991,
      );
    });

    for (final bad in [AnalyticsInt.maxSafe + 1, -AnalyticsInt.maxSafe - 1]) {
      test('rejects $bad', () {
        expect(() => AnalyticsInt(bad), throwsArgumentError);
      });
    }
  });

  group('AnalyticsDouble', () {
    test('accepts a finite value', () {
      expect(AnalyticsDouble(1.5).wireValue, 1.5);
      expect(AnalyticsDouble(1.5).kind, AnalyticsValueKind.decimal);
    });

    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      test('rejects $bad', () {
        expect(() => AnalyticsDouble(bad), throwsArgumentError);
      });
    }
  });

  group('AnalyticsToken', () {
    test('sends the enum member name', () {
      final t = AnalyticsToken(_Colour.green, vocabulary: _Colour.values);
      expect(t.wireValue, 'green');
      expect(t.kind, AnalyticsValueKind.token);
      expect(t.vocabularyNames, ['red', 'green', 'unknown']);
    });

    test('accepts the unknown sentinel', () {
      expect(
        AnalyticsToken(_Colour.unknown, vocabulary: _Colour.values).wireValue,
        'unknown',
      );
    });

    test('equality ignores the type argument', () {
      final inferred = AnalyticsToken(_Colour.red, vocabulary: _Colour.values);
      final widened = AnalyticsToken<Enum>(
        _Colour.red,
        vocabulary: _Colour.values,
      );
      expect(widened, inferred);
      expect(widened.hashCode, inferred.hashCode);
      expect(
        widened,
        isNot(AnalyticsToken(_Colour.green, vocabulary: _Colour.values)),
      );
    });

    test('keeps its vocabulary when the caller changes the list', () {
      final vocabulary = [_Colour.red, _Colour.green];
      final t = AnalyticsToken(_Colour.red, vocabulary: vocabulary);

      vocabulary.clear();

      expect(t.vocabularyNames, ['red', 'green']);
    });

    test('rejects a member outside the vocabulary at runtime', () {
      expect(
        () => AnalyticsToken<Enum>(_Other.red, vocabulary: _Colour.values),
        throwsArgumentError,
      );
    });
  });

  group('AnalyticsId', () {
    test('accepts a 24-char cuid2 and a 32-char one', () {
      expect(
        AnalyticsId('tz4a98xxat96iws9zmbrgj3a').wireValue,
        'tz4a98xxat96iws9zmbrgj3a',
      );
      expect(AnalyticsId('a${'b' * 31}').kind, AnalyticsValueKind.id);
    });

    for (final bad in [
      '',
      'Catan',
      'ticket to ride',
      'TZ4A98XXAT96IWS9ZMBRGJ3A',
      '1z4a98xxat96iws9zmbrgj3a',
      'tz4a98xxat96iws9zmbrgj3',
      'a${'b' * 32}',
      'tz4a98xx-t96iws9zmbrgj3a',
    ]) {
      test('rejects "$bad"', () {
        expect(() => AnalyticsId(bad), throwsArgumentError);
      });
    }
  });

  test('values compare by kind and value', () {
    expect(AnalyticsInt(1), AnalyticsInt(1));
    expect(AnalyticsInt(1), isNot(AnalyticsDouble(1)));
    expect(
      AnalyticsToken(_Colour.red, vocabulary: _Colour.values),
      AnalyticsToken(_Colour.red, vocabulary: _Colour.values),
    );
    expect(
      AnalyticsId('tz4a98xxat96iws9zmbrgj3a').hashCode,
      AnalyticsId('tz4a98xxat96iws9zmbrgj3a').hashCode,
    );
  });
}
