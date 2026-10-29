import 'package:app_shell/app_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The browser's session history as the web engine keeps it, for the web
/// composition's URL reflection (#321).
///
/// Each location the router reports becomes a new entry, or takes the
/// current one's place when the report asks to replace it. [back] hands the
/// router the entry before, location and state together, over the channel
/// the engine uses on popstate.
class FakeBrowserHistory {
  FakeBrowserHistory._(this._tester);

  /// Turns on [reflectPushedRoutesInUrl], as the web composition does, and
  /// records what the router reports from then on. Both are undone at the
  /// test's end.
  factory FakeBrowserHistory.install(WidgetTester tester) {
    final history = FakeBrowserHistory._(tester);
    reflectPushedRoutesInUrl();
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(SystemChannels.navigation, history._record);
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.navigation, null);
      GoRouter.optionURLReflectsImperativeAPIs = false;
    });
    return history;
  }

  final WidgetTester _tester;
  final _entries = <({String uri, Object? state})>[];
  var _current = -1;

  /// The entries up to and including the current one, oldest first.
  List<String> get locations => [
    for (final entry in _entries.take(_current + 1)) entry.uri,
  ];

  Future<Object?> _record(MethodCall call) async {
    if (call.method != 'routeInformationUpdated') return null;
    final arguments = call.arguments as Map<Object?, Object?>;
    final entry = (uri: arguments['uri']! as String, state: arguments['state']);
    if (arguments['replace'] == true && _current >= 0) {
      _entries[_current] = entry;
    } else {
      _entries
        ..removeRange(_current + 1, _entries.length)
        ..add(entry);
      _current++;
    }
    return null;
  }

  /// Browser Back: the router is handed the entry before the current one.
  Future<void> back() async {
    final entry = _entries[--_current];
    await _tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        MethodCall('pushRouteInformation', {
          'location': entry.uri,
          'state': entry.state,
        }),
      ),
      (_) {},
    );
    await _tester.pumpAndSettle();
  }
}
