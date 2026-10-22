import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;
import 'package:web_network/web_network.dart'
    show SessionChange, SessionChannel, WebSessionBindings;

/// The browser half of the session monitor (#432), handed to
/// `bootstrapWebServerScope` by `buildWebServerScope`.
///
/// Here rather than in `web_network`, which compiles for every target and so
/// cannot name `dart:js_interop`. Same split, and the same reason, as the
/// drift/wasm executor beside it.
const WebSessionBindings webSessionBindings = WebSessionBindings(
  openChannel: BroadcastSessionChannel.new,
  attention: pageAttention,
);

/// A [SessionChannel] over the browser's `BroadcastChannel` (#432).
///
/// Every channel of one name in an origin hears what the others post, a
/// second one in the same page included, and never its own. A message is
/// the change's name and nothing else; see [SessionChange] for why it names
/// no user.
class BroadcastSessionChannel implements SessionChannel {
  /// Opens the channel [name].
  BroadcastSessionChannel(String name) : _channel = web.BroadcastChannel(name) {
    _channel.onmessage = _onMessage.toJS;
  }

  final web.BroadcastChannel _channel;
  final StreamController<SessionChange> _changes =
      StreamController<SessionChange>.broadcast();
  var _closed = false;

  void _onMessage(web.MessageEvent event) {
    if (_closed) return;
    final data = event.data;
    // Anything else came from another build of the app, which this one
    // cannot act on. Dropped, not reported: there is no one to tell.
    if (!data.isA<JSString>()) return;
    final name = (data! as JSString).toDart;
    for (final change in SessionChange.values) {
      if (change.name == name) {
        _changes.add(change);
        return;
      }
    }
  }

  @override
  void post(SessionChange change) {
    // A closed `BroadcastChannel` throws on post.
    if (_closed) return;
    _channel.postMessage(change.name.toJS);
  }

  @override
  Stream<SessionChange> get changes => _changes.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _channel
      ..onmessage = null
      ..close();
    await _changes.close();
  }
}

/// Fires when the page regains the user's attention: the window gaining
/// focus, or the page turning visible (#432).
///
/// Both, because each misses a case the other catches. Switching back to a
/// tab turns it visible; a window left visible beside another one gains
/// focus without ever having been hidden.
///
/// Once per return, though: switching tabs usually fires both, and the
/// monitor reads the cookie for every event. It fires only after the page
/// has lost focus or been hidden. The monitor used to fold the pair itself,
/// by skipping an event while the previous one's read was out, and that also
/// folded two separate returns into one whenever the read was slow.
///
/// The listeners go on when the stream is first listened to and come off
/// when the last listener cancels.
Stream<void> pageAttention() {
  late final StreamController<void> controller;
  // Whether the page has lost focus or been hidden since it last fired.
  var away = false;
  void arrive() {
    if (!away) return;
    away = false;
    controller.add(null);
  }

  final onFocus = ((web.Event _) => arrive()).toJS;
  final onBlur = ((web.Event _) => away = true).toJS;
  final onVisibility = ((web.Event _) {
    if (web.document.visibilityState == 'visible') {
      arrive();
    } else {
      away = true;
    }
  }).toJS;

  controller = StreamController<void>.broadcast(
    onListen: () {
      // A page opened in the background, or without focus, has not had the
      // user's attention yet, so its first arrival counts.
      away =
          web.document.visibilityState != 'visible' || !web.document.hasFocus();
      web.window
        ..addEventListener('focus', onFocus)
        ..addEventListener('blur', onBlur);
      web.document.addEventListener('visibilitychange', onVisibility);
    },
    onCancel: () {
      web.window
        ..removeEventListener('focus', onFocus)
        ..removeEventListener('blur', onBlur);
      web.document.removeEventListener('visibilitychange', onVisibility);
    },
  );
  return controller.stream;
}
