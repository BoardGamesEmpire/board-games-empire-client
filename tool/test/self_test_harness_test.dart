// The shared self-test harness behind each tool/ script's --self-test
// (#808).
import 'package:test/test.dart';

import '../src/self_test.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late List<int> exits;
  late SelfTest selfTest;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    exits = [];
    selfTest = SelfTest('demo', out: out, err: err, exit: exits.add);
  });

  test('a pass writes an ok line', () {
    selfTest.record('x', passed: true);

    expect(out.toString(), '  ok   x\n');
    expect(selfTest.failures, 0);
  });

  test('a failure writes FAIL with its detail and counts', () {
    selfTest.record('x', passed: false, detail: ': got 1');

    expect(out.toString(), '  FAIL x: got 1\n');
    expect(selfTest.failures, 1);
  });

  test('finish exits 1 after failures', () {
    selfTest
      ..record('x', passed: false)
      ..finish();

    expect(exits, [1]);
    expect(err.toString(), endsWith('1 self-test failure(s).\n'));
    expect(out.toString(), isNot(contains('passed')));
  });

  test('finish reports a pass', () {
    selfTest
      ..record('x', passed: true)
      ..finish();

    expect(out.toString(), endsWith('demo self-test passed.\n'));
    expect(exits, isEmpty);
  });
}
