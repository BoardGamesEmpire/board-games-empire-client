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

  /// Every entry, the ones Forward returns to included, oldest first.
  List<String> get allLocations => [for (final entry in _entries) entry.uri];

  /// Every location the router reported, in order, whether it added an
  /// entry or took the current one's place. A replaced report leaves no
  /// entry behind, so only this shows that it happened.
  List<String> get reported => List.unmodifiable(_reported);
  final _reported = <String>[];

  Future<Object?> _record(MethodCall call) async {
    if (call.method != 'routeInformationUpdated') return null;
    final arguments = call.arguments as Map<Object?, Object?>;
    final entry = (uri: arguments['uri']! as String, state: arguments['state']);
    _reported.add(entry.uri);
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

  /// Whether a [back] went past the first entry. A browser leaves the app
  /// then, for whatever page came before it, so the router is handed
  /// nothing.
  bool get leftApp => _leftApp;
  var _leftApp = false;

  /// Browser Back: the router is handed the entry before the current one.
  /// From the first entry, the app is left ([leftApp]).
  Future<void> back() async {
    if (_current <= 0) {
      _leftApp = true;
      return;
    }
    await _restore(_entries[--_current]);
  }

  /// Browser Forward: the router is handed the entry after the current one.
  Future<void> forward() => _restore(_entries[++_current]);

  Future<void> _restore(({String uri, Object? state}) entry) async {
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
