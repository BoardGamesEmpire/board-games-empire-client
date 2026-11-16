import 'dart:io';

/// Runs `flutter` with [args] in [workingDirectory], its output streamed
/// through this process's own (#808).
///
/// When flutter fails, says which command failed and exits with its code,
/// so a script's caller sees the build's own exit code.
Future<void> runFlutter(
  List<String> args, {
  required String workingDirectory,
  Map<String, String>? environment,
}) async {
  final flutter = await Process.start(
    'flutter',
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
    // `flutter` is a batch file on Windows, which needs a shell to start.
    runInShell: Platform.isWindows,
  );
  final code = await flutter.exitCode;
  if (code != 0) {
    stderr.writeln('flutter ${args.join(' ')} failed with exit code $code.');
    exit(code);
  }
}
