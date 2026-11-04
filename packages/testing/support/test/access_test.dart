import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('FakeCallerAccessRepository', () {
    test('starts unknown, or with the answer it was given', () {
      expect(
        FakeCallerAccessRepository().current,
        const CallerAccess.unknown(),
      );

      final known = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      expect(FakeCallerAccessRepository(known).current, known);
    });

    test('emits each answer set that differs from the last', () async {
      final repository = FakeCallerAccessRepository();
      final emitted = <CallerAccess>[];
      final sub = repository.changes.listen(emitted.add);
      addTearDown(sub.cancel);
      final reader = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );

      repository
        ..current = reader
        ..current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        )
        ..current = const CallerAccess.unknown();
      await pumpEventQueue();

      expect(emitted, [reader, const CallerAccess.unknown()]);
      expect(repository.current, const CallerAccess.unknown());
    });

    test('changes is one broadcast stream', () {
      final repository = FakeCallerAccessRepository();

      expect(repository.changes.isBroadcast, isTrue);
      expect(identical(repository.changes, repository.changes), isTrue);
    });

    test('dispose closes changes and keeps the last answer, as the '
        "session's reader does when its scope pops", () async {
      final known = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      final repository = FakeCallerAccessRepository(known);
      final emitted = <CallerAccess>[];
      var done = false;
      final sub = repository.changes.listen(
        emitted.add,
        onDone: () => done = true,
      );
      addTearDown(sub.cancel);

      repository
        ..dispose()
        // An answer landing after the session ended is dropped, and a second
        // dispose does nothing.
        ..current = const CallerAccess.unknown()
        ..dispose();
      await pumpEventQueue();

      expect(done, isTrue);
      expect(emitted, isEmpty);
      expect(repository.current, known);
    });

    test('counts refreshes', () async {
      final repository = FakeCallerAccessRepository();

      await repository.refresh();
      unawaited(repository.refresh());

      expect(repository.refreshCount, 2);
    });

    test('dataGateway answers for DataGateways alone, with manage none', () {
      final access = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
        read: AccessExtent.some,
      );

      expect(access.isKnown, isTrue);
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.create),
        isTrue,
      );
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.read),
        isTrue,
      );
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.update),
        isFalse,
      );
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.delete),
        isFalse,
      );
      expect(
        access.allows(ResourceType.dataGateway, AccessAction.manage),
        isFalse,
      );
      expect(
        FakeCallerAccessRepository.dataGateway().deniesEverything,
        isTrue,
      );
    });
  });
}
