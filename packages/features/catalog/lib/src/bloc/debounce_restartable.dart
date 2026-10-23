import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Waits until events stop arriving for [duration], then handles the last
/// one, cancelling a handler still running for an earlier one (#42).
///
/// An event [immediate] picks is handled at once instead, and a wait still
/// running for an earlier one is dropped.
///
/// The debounce is written here rather than taken from `stream_transform`:
/// it is the one operator this package needs, and not worth a dependency.
/// The cancelling is `bloc_concurrency`'s `restartable()`.
///
/// A cancelled handler's later emits are dropped, but its awaited call still
/// finishes. A bloc that has more than one way to start the same work still
/// needs its own guard against an older answer, because `restartable()` only
/// orders events of one type.
EventTransformer<E> debounceRestartable<E>(
  Duration duration, {
  bool Function(E event)? immediate,
}) =>
    (events, mapper) =>
        restartable<E>()(_debounced(events, duration, immediate), mapper);

Stream<E> _debounced<E>(
  Stream<E> source,
  Duration duration,
  bool Function(E event)? immediate,
) {
  Timer? timer;
  StreamSubscription<E>? subscription;
  late final StreamController<E> controller;
  controller = StreamController<E>(
    onListen: () {
      subscription = source.listen(
        (event) {
          timer?.cancel();
          if (immediate?.call(event) ?? false) {
            controller.add(event);
          } else {
            timer = Timer(duration, () => controller.add(event));
          }
        },
        onError: controller.addError,
        onDone: () {
          // An event still waiting when the bloc closes is dropped: nothing
          // is left to handle it.
          timer?.cancel();
          unawaited(controller.close());
        },
      );
    },
    onCancel: () {
      timer?.cancel();
      return subscription?.cancel();
    },
  );
  return controller.stream;
}
