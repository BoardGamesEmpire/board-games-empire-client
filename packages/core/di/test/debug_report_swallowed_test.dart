import 'package:di/src/debug_report_swallowed.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String?> printed;
  late DebugPrintCallback original;

  setUp(() {
    printed = [];
    original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    addTearDown(() => debugPrint = original);
  });

  test('removes a database error\'s bound values (#463)', () {
    debugReportSwallowed(
      'scope disposal threw',
      'Bad state: Tried to send Request (id = 3): StatementMethod.insert: '
          'INSERT INTO t (a) VALUES (?) with [user-42] over isolate channel, '
          'but the connection was closed!',
    );

    expect(printed.single, startsWith('scope disposal threw: Bad state'));
    expect(printed.single, isNot(contains('user-42')));
  });

  test('prints any other error as it is', () {
    debugReportSwallowed('scope disposal threw', StateError('boom'));

    expect(printed.single, 'scope disposal threw: Bad state: boom');
  });
}
