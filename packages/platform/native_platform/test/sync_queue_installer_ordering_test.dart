import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:native_platform/native_platform.dart';
import 'package:sync_queue/sync_queue.dart';

/// Native's user-scope list holds the sync queue's sender and drain (#121),
/// in an order their dependencies make load-bearing.
///
/// The installers' own behaviour is tested where they live
/// (`packages/features/sync/test/sync_installers_test.dart`). What stays here
/// is the part about *this* composition root. The web list holds the sender
/// alone; its test is in
/// `packages/platform/web/test/web_user_scope_installers_test.dart`.
void main() {
  test('the list holds the sender and the drain once each', () {
    final installers = buildNativeUserScopeInstallers();

    expect(installers.whereType<SyncSenderInstaller>(), hasLength(1));
    expect(installers.whereType<SyncQueueDrainInstaller>(), hasLength(1));
  });

  test('the sender runs after the tier registering what it sends '
      'through', () {
    final installers = buildNativeUserScopeInstallers();

    final storage = installers.indexWhere(
      (i) => i is UserSessionScopeInstaller,
    );
    final sender = installers.indexWhere((i) => i is SyncSenderInstaller);

    expect(storage, isNonNegative);
    expect(sender, greaterThan(storage));
  });

  test('the drain runs after the sender it resolves, the rehydrator it '
      'registers with, and both hydrates', () {
    final installers = buildNativeUserScopeInstallers();
    int indexOf(bool Function(Object) test) => installers.indexWhere(test);

    final drain = indexOf((i) => i is SyncQueueDrainInstaller);

    expect(drain, greaterThan(indexOf((i) => i is SyncSenderInstaller)));
    expect(drain, greaterThan(indexOf((i) => i is SessionRehydratorInstaller)));
    // The rehydrator runs its entries in registration order, so each pass
    // runs the drain after both hydrates.
    expect(drain, greaterThan(indexOf((i) => i is HouseholdHydrateInstaller)));
    expect(
      drain,
      greaterThan(indexOf((i) => i is GameCollectionHydrateInstaller)),
    );
  });
}
