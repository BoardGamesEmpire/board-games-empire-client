import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('PrintLogSink', () {
    test('writes one formatted flat line per record via out', () {
      final lines = <String>[];
      PrintLogSink(
        out: lines.add,
        formatter: const LogRecordFormatter(includeTimestamp: false),
      ).emit(LogRecord(Level.WARNING, 'heads up', 'bge.web'));
      expect(lines, ['[WARN] bge.web: heads up']);
    });

    test('close is a no-op that completes', () {
      expect(PrintLogSink(out: (_) {}).close(), completes);
    });
  });
}
