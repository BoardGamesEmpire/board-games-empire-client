import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('BgeLogLevel.level', () {
    test('maps the five BGE levels onto package:logging levels', () {
      expect(BgeLogLevel.verbose.level, Level.FINEST);
      expect(BgeLogLevel.debug.level, Level.FINE);
      expect(BgeLogLevel.info.level, Level.INFO);
      expect(BgeLogLevel.warn.level, Level.WARNING);
      expect(BgeLogLevel.error.level, Level.SEVERE);
    });
  });

  group('BgeLogLevel.fromLevel', () {
    test('round-trips every BGE level', () {
      for (final level in BgeLogLevel.values) {
        expect(BgeLogLevel.fromLevel(level.level), level);
      }
    });

    test('collapses package:logging levels without a direct peer', () {
      // FINER sits between FINEST (verbose) and FINE (debug).
      expect(BgeLogLevel.fromLevel(Level.FINER), BgeLogLevel.verbose);
      // CONFIG sits between FINE (debug) and INFO.
      expect(BgeLogLevel.fromLevel(Level.CONFIG), BgeLogLevel.debug);
      // SHOUT is above SEVERE.
      expect(BgeLogLevel.fromLevel(Level.SHOUT), BgeLogLevel.error);
    });

    test('handles custom levels by threshold', () {
      expect(
        BgeLogLevel.fromLevel(const Level('CUSTOM', 850)),
        BgeLogLevel.info,
      );
      expect(
        BgeLogLevel.fromLevel(const Level('CUSTOM', 950)),
        BgeLogLevel.warn,
      );
    });
  });

  group('wire helpers', () {
    const expectations = {
      BgeLogLevel.verbose: 'verbose',
      BgeLogLevel.debug: 'debug',
      BgeLogLevel.info: 'info',
      BgeLogLevel.warn: 'warn',
      BgeLogLevel.error: 'error',
    };

    test('toWire covers every variant', () {
      expect(expectations.keys.toSet(), BgeLogLevel.values.toSet());
      expectations.forEach((level, wire) {
        expect(level.toWire(), wire);
      });
    });

    test('fromWire parses every wire string', () {
      expectations.forEach((level, wire) {
        expect(BgeLogLevel.fromWire(wire), level);
      });
    });

    test('round-trip', () {
      for (final level in BgeLogLevel.values) {
        expect(BgeLogLevel.fromWire(level.toWire()), level);
      }
    });

    test('fromWire throws on an unrecognised value', () {
      // Strict — these strings are client-authored; an unknown value is
      // corruption, not a server enum extension.
      expect(() => BgeLogLevel.fromWire('TRACE'), throwsStateError);
    });
  });
}
