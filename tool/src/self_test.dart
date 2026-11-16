import 'dart:io' as io;

/// The harness behind each tool/ script's `--self-test` (#808): the
/// `ok` / `FAIL` lines, the failure count and the exit code.
///
/// Each script keeps its own typed expect, written on top of [record], since
/// what one compares (JSON, strings, a condition, a domain check) is its
/// own. Every line goes to [StringSink]s given at construction, stdout and
/// stderr by default, so the harness can test itself.
final class SelfTest {
  /// A self-test for the script it is given, which the line [finish] writes
  /// on a pass names.
  SelfTest(
    this._script, {
    StringSink? out,
    StringSink? err,
    void Function(int code)? exit,
  }) : _out = out ?? io.stdout,
       _err = err ?? io.stderr,
       _exit = exit ?? io.exit;

  final String _script;
  final StringSink _out;
  final StringSink _err;
  final void Function(int code) _exit;
  var _failures = 0;

  /// The failures counted so far.
  int get failures => _failures;

  /// Writes `ok` for a case that [passed], or counts a failure and writes
  /// `FAIL` with [detail] after the name.
  void record(String name, {required bool passed, String detail = ''}) {
    if (passed) {
      _out.writeln('  ok   $name');
    } else {
      _failures++;
      _out.writeln('  FAIL $name$detail');
    }
  }

  /// Ends the self-test: exits 1 when anything failed, and otherwise says it
  /// passed.
  void finish() {
    if (_failures > 0) {
      _err.writeln('\n$_failures self-test failure(s).');
      _exit(1);
      return;
    }
    _out.writeln('$_script self-test passed.');
  }
}
