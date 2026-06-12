import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('FeedbackCategory wire helpers', () {
    const expectations = {
      FeedbackCategory.bug: 'Bug',
      FeedbackCategory.crash: 'Crash',
      FeedbackCategory.featureRequest: 'FeatureRequest',
    };

    test('toWire covers every variant with the PascalCase server string', () {
      expect(expectations.keys.toSet(), FeedbackCategory.values.toSet());
      expectations.forEach((category, wire) {
        expect(category.toWire(), wire);
      });
    });

    test('fromWire parses every wire string', () {
      expectations.forEach((category, wire) {
        expect(FeedbackCategory.fromWire(wire), category);
      });
    });

    test('round-trip', () {
      for (final category in FeedbackCategory.values) {
        expect(FeedbackCategory.fromWire(category.toWire()), category);
      }
    });

    test('fromWire throws on an unrecognised value', () {
      expect(() => FeedbackCategory.fromWire('Praise'), throwsStateError);
    });
  });

  group('FeedbackContext wire helpers', () {
    const expectations = {
      FeedbackContext.client: 'Client',
      FeedbackContext.server: 'Server',
      FeedbackContext.unknown: 'Unknown',
    };

    test('toWire covers every variant', () {
      expect(expectations.keys.toSet(), FeedbackContext.values.toSet());
      expectations.forEach((context, wire) {
        expect(context.toWire(), wire);
      });
    });

    test('round-trip', () {
      for (final context in FeedbackContext.values) {
        expect(FeedbackContext.fromWire(context.toWire()), context);
      }
    });

    test('fromWire throws on an unrecognised value', () {
      expect(() => FeedbackContext.fromWire('Edge'), throwsStateError);
    });
  });

  group('FeedbackSeverity wire helpers', () {
    const expectations = {
      FeedbackSeverity.low: 'Low',
      FeedbackSeverity.medium: 'Medium',
      FeedbackSeverity.high: 'High',
      FeedbackSeverity.critical: 'Critical',
    };

    test('toWire covers every variant', () {
      expect(expectations.keys.toSet(), FeedbackSeverity.values.toSet());
      expectations.forEach((severity, wire) {
        expect(severity.toWire(), wire);
      });
    });

    test('round-trip', () {
      for (final severity in FeedbackSeverity.values) {
        expect(FeedbackSeverity.fromWire(severity.toWire()), severity);
      }
    });

    test('fromWire throws on an unrecognised value', () {
      expect(() => FeedbackSeverity.fromWire('Blocker'), throwsStateError);
    });
  });
}
