import 'package:flutter/widgets.dart';

/// Route-independent system-back interception for subtrees that render
/// **above** the router's Navigator (#106).
///
/// The crash flow (#69/#76) lives in `MaterialApp.builder`, over a
/// [ModalBarrier], with no route of its own — so none of the usual
/// primitives apply:
///
/// - `PopScope` registers with a `ModalRoute`; the overlay has none → no-op.
/// - `BackButtonListener` registers via `Router.of(context)`, requiring a
///   `Router` **ancestor** — but in `MaterialApp.router` the `builder`
///   *wraps* the Router (the Router is the builder's **child**), so
///   registration would fail from the overlay subtree.
/// - A late-registered `WidgetsBindingObserver.didPopRoute` never fires
///   either: `WidgetsBinding.handlePopRoute` consults observers in
///   **registration order**, and the router's `RootBackButtonDispatcher`
///   (registered at first Router attach) consumes the pop first.
///
/// What does work: the host owns the `GoRouter` instance and therefore its
/// [BackButtonDispatcher]. This widget creates a
/// [ChildBackButtonDispatcher] on it and takes priority — the framework's
/// sanctioned interception mechanism (the same one `BackButtonListener`
/// rides) — so while mounted, system back reaches [onBack] **before** the
/// router's own pop handling. Returning true consumes the press; returning
/// false falls through to the router.
///
/// Mount it only while interception should be active (the crash overlay
/// mounts it only while a draft is pending); [dispose] detaches cleanly and
/// the router resumes normal back handling.
///
/// Predictive back caveat: back currently arrives on the legacy `popRoute`
/// channel (the Android manifest does not set
/// `enableOnBackInvokedCallback`), which flows through the dispatcher chain
/// as described. Enabling predictive back later changes the delivery path
/// and requires revisiting this widget.
class RouterBackInterceptor extends StatefulWidget {
  const RouterBackInterceptor({
    required this.dispatcher,
    required this.onBack,
    super.key,
  });

  /// The router's dispatcher (e.g. `GoRouter.backButtonDispatcher`). When
  /// null (defensive — GoRouter always supplies one) the interceptor is
  /// inert and back handling is unchanged.
  final BackButtonDispatcher? dispatcher;

  /// Invoked on a system back press while mounted. Return true to consume
  /// the press, false to let the router handle it.
  final Future<bool> Function() onBack;

  @override
  State<RouterBackInterceptor> createState() => _RouterBackInterceptorState();
}

class _RouterBackInterceptorState extends State<RouterBackInterceptor> {
  ChildBackButtonDispatcher? _child;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(RouterBackInterceptor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dispatcher != widget.dispatcher) {
      _detach();
      _attach();
    }
  }

  void _attach() {
    final parent = widget.dispatcher;
    if (parent == null) return;
    final child = parent.createChildBackButtonDispatcher()
      ..addCallback(_handleBack)
      ..takePriority();
    _child = child;
  }

  void _detach() {
    // Removing the last callback makes the child dispatcher deregister
    // itself from its parent (ChildBackButtonDispatcher.removeCallback →
    // parent.forget), restoring the router's normal back handling.
    _child?.removeCallback(_handleBack);
    _child = null;
  }

  /// Kept as a tear-off-stable method: add/removeCallback must see the
  /// same function identity.
  Future<bool> _handleBack() => widget.onBack();

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
