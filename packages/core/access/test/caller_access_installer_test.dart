import 'dart:async';

import 'package:access/access.dart';
import 'package:fake_async/fake_async.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:logging/logging.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const _server = ScopedServer(serverId: 'server-1', displayName: 'Server');

/// Records what the installer registers with it.
class _FakeRehydrator implements SessionRehydrator {
  final keys = <String>[];
  late bool Function() isStale;
  late Future<void> Function() run;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {
    keys.add(key);
    this.isStale = isStale;
    this.run = run;
  }

  @override
  Future<void> rehydrateStale() => throw UnimplementedError();
}

/// Resolves what a test registered, by type, keeps what the installer
/// registers, and runs their dispose callbacks on [dispose].
class _FakeContainer implements DependencyContainer {
  _FakeContainer([Map<Type, Object> registered = const {}])
    : _registered = {...registered};

  final Map<Type, Object> _registered;
  final _disposers = <FutureOr<void> Function()>[];

  @override
  bool isRegistered<T extends Object>() => _registered.containsKey(T);

  @override
  T get<T extends Object>() {
    final instance = _registered[T];
    if (instance == null) throw StateError('$T is not registered');
    return instance as T;
  }

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) {
    _registered[T] = instance;
    if (dispose != null) _disposers.add(() => dispose(instance));
  }

  @override
  Future<void> dispose() async {
    for (final disposer in _disposers) {
      await disposer();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late FakeUserRemote remote;
  late _FakeRehydrator rehydrator;

  setUp(() {
    remote = FakeUserRemote();
    rehydrator = _FakeRehydrator();
  });

  Future<void> install(
    DependencyContainer container, {
    Set<ResourceType> resourceTypes = dataGatewayOnly,
  }) =>
      CallerAccessInstaller(resourceTypes: resourceTypes)
          .install(container, _server, 'user-1');

  test('registers the repository and starts the first ask', () async {
    final pending = Completer<Map<ResourceType, ResourceAccess>>();
    remote.replies.add(pending);
    final container = _FakeContainer({UserRemoteDataSource: remote});

    // Returns with the ask still out: a wait here would hold up sign-in.
    await install(container);

    final repository = container.get<CallerAccessRepository>();
    expect(repository, isA<CallerAccessReader>());
    expect(remote.asked, [dataGatewayOnly]);

    pending.complete(allAnswer);
    await pumpEventQueue();

    expect(repository.current, const CallerAccess.known(allAnswer));
  });

  test('the session teardown disposes the reader', () async {
    remote.replies.add(allAnswer);
    final container = _FakeContainer({UserRemoteDataSource: remote});
    await install(container);
    final closed = expectLater(
      container.get<CallerAccessRepository>().changes,
      emitsDone,
    );

    await container.dispose();

    await closed;
  });

  test('registers with the rehydrator as caller_access, stale whenever no ask '
      'is in flight', () {
    fakeAsync((async) {
      final first = Completer<Map<ResourceType, ResourceAccess>>();
      remote.replies.addAll([first, allAnswer]);
      final container = _FakeContainer({
        UserRemoteDataSource: remote,
        SessionRehydrator: rehydrator,
      });

      unawaited(install(container));
      async.flushMicrotasks();

      expect(rehydrator.keys, ['caller_access']);
      expect(rehydrator.isStale(), isFalse, reason: 'the first ask is out');

      first.complete(noneAnswer);
      async.flushMicrotasks();
      expect(rehydrator.isStale(), isFalse, reason: 'waiting to ask again');

      async.elapse(const Duration(seconds: 2));
      expect(remote.requests, 2);
      expect(rehydrator.isStale(), isTrue, reason: 'settled');
    });
  });

  test('a rehydrate pass asks again after an answer is known', () async {
    remote.replies.addAll([allAnswer, allAnswer]);
    final container = _FakeContainer({
      UserRemoteDataSource: remote,
      SessionRehydrator: rehydrator,
    });
    await install(container);
    await pumpEventQueue();
    expect(container.get<CallerAccessRepository>().current.isKnown, isTrue);

    await rehydrator.run();

    expect(remote.requests, 2);
  });

  test("a rehydrate pass doesn't wait on the ask it starts, so the entries "
      'after it run at once', () async {
    final slow = Completer<Map<ResourceType, ResourceAccess>>();
    remote.replies.addAll([allAnswer, slow]);
    final container = _FakeContainer({
      UserRemoteDataSource: remote,
      SessionRehydrator: rehydrator,
    });
    await install(container);
    await pumpEventQueue();

    var ran = false;
    unawaited(rehydrator.run().then((_) => ran = true));
    await pumpEventQueue();

    expect(remote.requests, 2);
    expect(ran, isTrue, reason: 'the ask is still out');
    expect(rehydrator.isStale(), isFalse, reason: 'a second pass joins it');

    slow.complete(allAnswer);
    await pumpEventQueue();
    expect(rehydrator.isStale(), isTrue);
  });

  test('a first ask that failed while online is asked again on the next '
      'rehydrate pass', () async {
    remote.replies.addAll([
      const UserRemoteTransientException('502 from a proxy'),
      allAnswer,
    ]);
    final container = _FakeContainer({
      UserRemoteDataSource: remote,
      SessionRehydrator: rehydrator,
    });
    await install(container);
    await pumpEventQueue();
    final repository = container.get<CallerAccessRepository>();
    expect(repository.current, const CallerAccess.unknown());
    expect(rehydrator.isStale(), isTrue);

    await rehydrator.run();
    await pumpEventQueue();

    expect(remote.requests, 2);
    expect(repository.current, const CallerAccess.known(allAnswer));
  });

  test('asks the session guard the scope registers (#432)', () async {
    final guard = FakeGuard(SessionConfirmation.notThisUser);
    remote.replies.add(allAnswer);
    final container = _FakeContainer({
      UserRemoteDataSource: remote,
      SessionIdentityGuard: guard,
    });

    await install(container);
    await pumpEventQueue();

    expect(guard.askedFor, ['user-1']);
    expect(
      container.get<CallerAccessRepository>().current,
      const CallerAccess.unknown(),
    );
  });

  group('registers nothing', () {
    test('without a UserRemoteDataSource', () async {
      final logs = captureLogs('bge.access');
      final container = _FakeContainer({SessionRehydrator: rehydrator});

      await install(container);

      expect(container.isRegistered<CallerAccessRepository>(), isFalse);
      expect(rehydrator.keys, isEmpty);
      expect(logs.map((r) => r.level), [Level.FINE]);
    });

    test('for an empty type set', () async {
      final logs = captureLogs('bge.access');
      final container = _FakeContainer({
        UserRemoteDataSource: remote,
        SessionRehydrator: rehydrator,
      });

      await install(container, resourceTypes: const {});

      expect(container.isRegistered<CallerAccessRepository>(), isFalse);
      expect(rehydrator.keys, isEmpty);
      expect(remote.requests, 0);
      expect(logs.map((r) => r.level), [Level.FINE]);
    });
  });
}
