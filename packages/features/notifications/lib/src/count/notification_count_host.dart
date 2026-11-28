import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:network_interface/network_interface.dart';

import 'package:notifications/src/count/notification_count_cubit.dart';

/// Owns the [NotificationCountCubit] for one session and provides it to
/// [child] (#475).
///
/// Reads the count on mount and each time the app resumes. The cubit is
/// bound to [remote] for the life of this State: key the host on the session
/// so a new server or sign-in starts from an unknown count.
class NotificationCountHost extends StatefulWidget {
  const NotificationCountHost({
    required this.remote,
    required this.child,
    super.key,
  });

  final NotificationRemoteDataSource remote;
  final Widget child;

  @override
  State<NotificationCountHost> createState() => _NotificationCountHostState();
}

class _NotificationCountHostState extends State<NotificationCountHost> {
  late final NotificationCountCubit _cubit;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _cubit = NotificationCountCubit(widget.remote);
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_cubit.refresh()),
    );
    unawaited(_cubit.refresh());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_cubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      BlocProvider.value(value: _cubit, child: widget.child);
}
