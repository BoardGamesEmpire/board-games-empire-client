import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// Edge length of the box that carries the error announcement's semantics.
///
/// **Not a spacing decision, which is why it is named rather than inline.** A
/// semantics node with an empty rect can be dropped when the tree is compiled,
/// and a dropped node announces nothing; this is the smallest box that is
/// guaranteed to survive. `SizedBox.shrink()` does not.
///
/// Naming it also removes the need for a file-wide `spacing` exemption in
/// `design_system_enforcement_test.dart`. A blanket exemption would have kept
/// itself alive on the strength of this one anchor while waving through every
/// future literal `SizedBox` in the file.
const double _semanticsAnchorExtent = 1;

/// A visually-imperceptible node that announces validation errors as they
/// appear. Deliberately 1x1 rather than zero-size — see
/// [_semanticsAnchorExtent].
///
/// The announcement rides a [Semantics.label] on a 1×1 box rather than
/// rendering invisible text. The earlier version of this widget drew a real
/// `Text` at `fontSize: 0` inside an `OverflowBox` — which put a raw font size
/// in the widget tree purely to hide something, and is the kind of trick that
/// gets "cleaned up" by someone who does not realize it is load-bearing.
///
/// ## Why it subscribes to two streams
///
/// The obvious implementation — wrapping this in `ReactiveFormConsumer` — is
/// what the auth-feature original did, and it **never fired**.
/// `ReactiveFormConsumer` rebuilds on value and status changes; becoming
/// *touched* is neither. So in the flow that actually produces errors —
/// submit an empty form, which calls `markAllAsTouched()` — the control went
/// from untouched-invalid to touched-invalid, no rebuild happened, and nothing
/// was ever announced.
///
/// Listening to `touchChanges` as well as `statusChanged` is what makes the
/// announcement real rather than nominal. Both are needed: status covers
/// "became invalid while already touched", touch covers "was already invalid
/// and just became touched".
///
/// ## Why the control is passed in rather than looked up
///
/// This used to resolve `formControlName` itself, from a one-shot
/// `didChangeDependencies` — its `ReactiveForm.of` call passed `listen: false`,
/// which registers no dependency, so it never ran a second time — plus a
/// `didUpdateWidget` that re-resolved only when the **name** changed. A group
/// swap changes neither, so the announcer stayed subscribed to a control that
/// was no longer on any form: silent about the field on screen, and still
/// announcing for the one that had gone away (#186).
///
/// Taking the already-resolved control as a parameter makes that staleness
/// impossible rather than merely handled — there is no lookup left to go
/// stale, and `didUpdateWidget` is a sufficient signal because the control now
/// arrives the same way every other piece of configuration does.
class LiveErrorAnnouncer extends StatefulWidget {
  const LiveErrorAnnouncer({
    required this.control,
    required this.validationMessages,
    super.key,
  });

  /// The control to announce for, already resolved by the field this sits
  /// under. Null when there is no enclosing group to resolve against, in which
  /// case there is nothing to announce and the field is the one that
  /// complains.
  final AbstractControl<dynamic>? control;
  final Map<String, String Function(Object)> validationMessages;

  @override
  State<LiveErrorAnnouncer> createState() => _LiveErrorAnnouncerState();
}

class _LiveErrorAnnouncerState extends State<LiveErrorAnnouncer> {
  AbstractControl<dynamic>? _control;
  StreamSubscription<ControlStatus>? _statusSub;
  StreamSubscription<bool>? _touchSub;

  @override
  void initState() {
    super.initState();
    _resubscribe();
  }

  @override
  void didUpdateWidget(LiveErrorAnnouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Unconditional, and the guard in `_resubscribe` is what makes that cheap.
    // The case worth catching is a *different control arriving under the same
    // name*, which no comparison of the widget's other fields can see.
    _resubscribe();
  }

  void _resubscribe() {
    final control = widget.control;
    if (identical(control, _control)) return;

    _unsubscribe();
    _control = control;
    if (control == null) return;

    _statusSub = control.statusChanged.listen(_onChanged);
    _touchSub = control.touchChanges.listen(_onChanged);
  }

  void _onChanged(Object? _) {
    if (mounted) setState(() {});
  }

  void _unsubscribe() {
    _statusSub?.cancel();
    _touchSub?.cancel();
    _statusSub = null;
    _touchSub = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final control = _control;
    if (control == null || !control.invalid || !control.touched) {
      return const SizedBox.shrink();
    }

    final errorKey = control.errors.keys.firstOrNull;
    if (errorKey == null) return const SizedBox.shrink();

    final message = widget.validationMessages[errorKey]?.call(
      control.errors[errorKey]!,
    );
    if (message == null) return const SizedBox.shrink();

    return Semantics(
      liveRegion: true,
      label: message,
      child: const SizedBox(
        width: _semanticsAnchorExtent,
        height: _semanticsAnchorExtent,
      ),
    );
  }
}
