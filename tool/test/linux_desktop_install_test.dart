// The Linux bundle's per-user install and uninstall scripts (#84).
@TestOn('!windows')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../src/workspace_root.dart';

const _appId = 'com.boardgamesempire.app';

void main() {
  late Directory tmp;
  late Directory stubs;
  late Directory home;
  late File log;
  late Directory root;
  late Directory coreutils;

  setUpAll(() {
    root = workspaceRoot(from: Directory.current);
    // The externals the two scripts run, linked into one directory so a run
    // never sees a real xdg-mime and friends on the system PATH.
    coreutils = Directory.systemTemp.createTempSync('linux_install_bin_');
    for (final name in [
      'dirname',
      'sed',
      'mkdir',
      'cp',
      'mv',
      'rm',
      'grep',
      'cat',
    ]) {
      final found = Process.runSync('/bin/sh', ['-c', 'command -v $name']);
      final path = '${found.stdout}'.trim();
      expect(path, startsWith('/'), reason: 'no $name on this machine');
      Link('${coreutils.path}/$name').createSync(path);
    }
  });
  tearDownAll(() => coreutils.deleteSync(recursive: true));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('linux_install_');
    stubs = Directory('${tmp.path}/stubs')..createSync();
    home = Directory('${tmp.path}/home')..createSync();
    log = File('${tmp.path}/tools.log')..writeAsStringSync('');
    for (final tool in [
      'update-desktop-database',
      'xdg-mime',
      'gtk-update-icon-cache',
    ]) {
      final stub = File('${stubs.path}/$tool')
        ..writeAsStringSync('#!/bin/sh\necho "$tool \$*" >> "${log.path}"\n');
      Process.runSync('chmod', ['+x', stub.path]);
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Lays out a bundle the way CMake installs it, under [parent].
  Directory makeBundle(String parent) {
    final bundle = Directory('${tmp.path}/$parent')
      ..createSync(recursive: true);
    final packaging = '${root.path}/apps/desktop/packaging/linux';
    for (final script in ['install-desktop.sh', 'uninstall-desktop.sh']) {
      File('$packaging/$script').copySync('${bundle.path}/$script');
      Process.runSync('chmod', ['+x', '${bundle.path}/$script']);
    }
    File('${bundle.path}/board_games_empire').writeAsStringSync('stub');
    Directory('${bundle.path}/share/applications').createSync(recursive: true);
    File(
      '$packaging/$_appId.desktop',
    ).copySync('${bundle.path}/share/applications/$_appId.desktop');
    Directory(
      '${bundle.path}/share/icons/hicolor/256x256/apps',
    ).createSync(recursive: true);
    File(
      '${root.path}/apps/desktop/macos/Runner/Assets.xcassets/'
      'AppIcon.appiconset/app_icon_256.png',
    ).copySync('${bundle.path}/share/icons/hicolor/256x256/apps/$_appId.png');
    return bundle;
  }

  ProcessResult run(Directory bundle, String script, {bool withTools = true}) {
    return Process.runSync(
      '/bin/sh',
      ['${bundle.path}/$script'],
      includeParentEnvironment: false,
      environment: {
        'HOME': home.path,
        'XDG_DATA_HOME': '${home.path}/data',
        'XDG_CONFIG_HOME': '${home.path}/config',
        'PATH': '${withTools ? '${stubs.path}:' : ''}${coreutils.path}',
      },
    );
  }

  File entry() => File('${home.path}/data/applications/$_appId.desktop');
  File icon() =>
      File('${home.path}/data/icons/hicolor/256x256/apps/$_appId.png');

  String execLine() =>
      entry().readAsLinesSync().singleWhere((l) => l.startsWith('Exec='));

  /// The `Exec=` line the key-file layer holds for a bundle at [path]: bare
  /// unless the path holds a character the spec reserves.
  String expectedExec(String path) {
    final percent = path.replaceAll('%', '%%');
    if (!RegExp('[ \t\n"\'\\\\><~|&;\$*?#()`]').hasMatch(path)) {
      return 'Exec=$percent/board_games_empire %u';
    }
    final escaped = path
        .replaceAll(r'\', r'\\\\')
        .replaceAll('"', r'\\"')
        .replaceAll('`', r'\\`')
        .replaceAll(r'$', r'\\$')
        .replaceAll('%', '%%');
    return 'Exec="$escaped/board_games_empire" %u';
  }

  test('installs the entry with an absolute Exec and the bge handler', () {
    final bundle = makeBundle('bundle');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(execLine(), 'Exec=${bundle.path}/board_games_empire %u');
    expect(
      entry().readAsLinesSync(),
      contains('MimeType=x-scheme-handler/bge;'),
    );
    expect(icon().existsSync(), isTrue);
    final calls = log.readAsStringSync();
    expect(
      calls,
      contains('xdg-mime default $_appId.desktop x-scheme-handler/bge'),
    );
    expect(calls, contains('update-desktop-database'));
    expect(calls, contains('gtk-update-icon-cache -f -t'));
  });

  test('quotes a bundle path with a space', () {
    final bundle = makeBundle('my apps/bge');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(execLine(), contains('/my apps/bge/board_games_empire" %u'));
    expect(execLine(), expectedExec(bundle.path));
  });

  test('writes a path whose only special character is % bare, doubled', () {
    final bundle = makeBundle('100%_bge');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(execLine(), contains('/100%%_bge/board_games_empire %u'));
    expect(execLine(), isNot(contains('"')));
    expect(execLine(), expectedExec(bundle.path));
  });

  test('escapes a dollar sign, a double quote and a backtick', () {
    final bundle = makeBundle(r'a$b"c`d');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(execLine(), contains(r'/a\\$b\\"c\\`d/board_games_empire" %u'));
    expect(execLine(), expectedExec(bundle.path));
  });

  test('quotes a path with a reserved character that is not a space', () {
    final bundle = makeBundle('a&b(c)');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(execLine(), contains('/a&b(c)/board_games_empire" %u'));
    expect(execLine(), startsWith('Exec="'));
    expect(execLine(), expectedExec(bundle.path));
  });

  test('escapes a backslash four-fold', () {
    final bundle = makeBundle(r'a\b');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(execLine(), contains(r'/a\\\\b/board_games_empire" %u'));
  });

  test('refuses a bundle path with a newline', () {
    final bundle = makeBundle('a\nb');

    final result = run(bundle, 'install-desktop.sh');

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('newline'));
    expect(entry().existsSync(), isFalse);
  });

  test('a second run after the bundle moved points at the new path', () {
    final bundle = makeBundle('first');
    expect(run(bundle, 'install-desktop.sh').exitCode, 0);

    final moved = bundle.renameSync('${tmp.path}/second');
    final result = run(moved, 'install-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      Directory('${home.path}/data/applications').listSync(),
      hasLength(1),
    );
    expect(execLine(), expectedExec(moved.path));
    expect(execLine(), contains('/second/'));
  });

  test('installs without the optional tools', () {
    final bundle = makeBundle('bundle');

    final result = run(bundle, 'install-desktop.sh', withTools: false);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(entry().existsSync(), isTrue);
    expect(icon().existsSync(), isTrue);
    expect(result.stdout, contains('Not found, so skipped:'));
    expect(result.stdout, contains('xdg-mime'));
    expect(log.readAsStringSync(), isEmpty);
  });

  /// Replaces the stub for [tool] with one that logs its call and fails.
  void failing(String tool) {
    File('${stubs.path}/$tool').writeAsStringSync(
      '#!/bin/sh\necho "$tool \$*" >> "${log.path}"\nexit 1\n',
    );
  }

  for (final tool in ['update-desktop-database', 'gtk-update-icon-cache']) {
    test('sets the bge default and succeeds when $tool fails', () {
      final bundle = makeBundle('bundle');
      failing(tool);

      final result = run(bundle, 'install-desktop.sh');

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, contains('$tool failed; continuing'));
      expect(
        log.readAsStringSync(),
        contains('xdg-mime default $_appId.desktop x-scheme-handler/bge'),
      );
      expect(log.readAsStringSync(), contains('gtk-update-icon-cache'));
    });
  }

  test('uninstall removes the default when update-desktop-database fails', () {
    final bundle = makeBundle('bundle');
    expect(run(bundle, 'install-desktop.sh').exitCode, 0);
    failing('update-desktop-database');
    final mimeapps = File('${home.path}/config/mimeapps.list')
      ..createSync(recursive: true)
      ..writeAsStringSync('x-scheme-handler/bge=$_appId.desktop\n');

    final result = run(bundle, 'uninstall-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(mimeapps.readAsStringSync(), isEmpty);
  });

  test('uninstall removes the entry, the icon and the default', () {
    final bundle = makeBundle('bundle');
    expect(run(bundle, 'install-desktop.sh').exitCode, 0);
    final mimeapps = File('${home.path}/config/mimeapps.list')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '[Default Applications]\n'
        'x-scheme-handler/bge=$_appId.desktop\n'
        'text/plain=other.desktop\n',
      );

    final result = run(bundle, 'uninstall-desktop.sh');

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(entry().existsSync(), isFalse);
    expect(icon().existsSync(), isFalse);
    expect(
      mimeapps.readAsStringSync(),
      '[Default Applications]\ntext/plain=other.desktop\n',
    );
  });

  group('uninstall and mimeapps.list', () {
    File seed(String content) => File('${home.path}/config/mimeapps.list')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    test('removes the form gio writes, with a trailing semicolon', () {
      final bundle = makeBundle('bundle');
      final mimeapps = seed(
        '[Added Associations]\n'
        'x-scheme-handler/bge=$_appId.desktop;\n'
        'text/plain=other.desktop;\n',
      );

      final result = run(bundle, 'uninstall-desktop.sh');

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        mimeapps.readAsStringSync(),
        '[Added Associations]\ntext/plain=other.desktop;\n',
      );
    });

    test('edits a symlinked file in place and leaves the link', () {
      final bundle = makeBundle('bundle');
      final target = File('${tmp.path}/dotfiles/mimeapps.list')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'x-scheme-handler/bge=$_appId.desktop\ntext/plain=other.desktop\n',
        );
      Directory('${home.path}/config').createSync(recursive: true);
      final link = Link('${home.path}/config/mimeapps.list')
        ..createSync(target.path);

      final result = run(bundle, 'uninstall-desktop.sh');

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(link.existsSync(), isTrue);
      expect(
        FileSystemEntity.isLinkSync(link.path),
        isTrue,
        reason: 'the symlink was replaced by a regular file',
      );
      expect(target.readAsStringSync(), 'text/plain=other.desktop\n');
    });

    test('leaves a line that lists another app too untouched', () {
      final bundle = makeBundle('bundle');
      const content =
          'x-scheme-handler/bge=other.desktop;$_appId.desktop;\n'
          'x-scheme-handler/bge=$_appId.desktop\n';
      final mimeapps = seed(content);

      final result = run(bundle, 'uninstall-desktop.sh');

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        mimeapps.readAsStringSync(),
        'x-scheme-handler/bge=other.desktop;$_appId.desktop;\n',
      );
    });
  });
}
