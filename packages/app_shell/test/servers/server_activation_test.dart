import 'package:app_shell/l10n/shell_localizations_en.dart';
import 'package:app_shell/src/servers/server_activation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockServerContext extends Mock implements ServerContext {}

void main() {
  late _MockServerOrchestrator orchestrator;

  setUp(() {
    orchestrator = _MockServerOrchestrator();
    when(() => orchestrator.switchActiveServer(any())).thenAnswer((_) async {});
    when(
      () => orchestrator.connectServer(
        any(),
        makeActive: any(named: 'makeActive'),
      ),
    ).thenAnswer((_) async {});
  });

  group('activateServer', () {
    test('a connected server is switched to', () async {
      when(() => orchestrator.getContext('s1'))
          .thenReturn(_MockServerContext());

      await activateServer(orchestrator, 's1');

      verify(() => orchestrator.switchActiveServer('s1')).called(1);
      verifyNever(
        () => orchestrator.connectServer(
          any(),
          makeActive: any(named: 'makeActive'),
        ),
      );
    });

    test('a disconnected server is connected and made active', () async {
      when(() => orchestrator.getContext('s1')).thenReturn(null);

      await activateServer(orchestrator, 's1');

      verify(() => orchestrator.connectServer('s1', makeActive: true))
          .called(1);
      verifyNever(() => orchestrator.switchActiveServer(any()));
    });

    test('a failure is rethrown', () async {
      final failure = StateError('boom');
      when(() => orchestrator.getContext('s1'))
          .thenReturn(_MockServerContext());
      when(() => orchestrator.switchActiveServer('s1')).thenThrow(failure);

      await expectLater(
        activateServer(orchestrator, 's1'),
        throwsA(same(failure)),
      );
    });

    test(
      'a server another caller connected while this call waited is switched to',
      () async {
        final contexts = <ServerContext?>[null, _MockServerContext()];
        when(() => orchestrator.getContext('s1')).thenAnswer(
          (_) => contexts.length > 1 ? contexts.removeAt(0) : contexts.first,
        );
        when(
          () => orchestrator.connectServer('s1', makeActive: true),
        ).thenThrow(StateError('Server s1 is already connected.'));

        await activateServer(orchestrator, 's1');

        verify(() => orchestrator.switchActiveServer('s1')).called(1);
      },
    );

    // The catch can't tell which StateError a connect threw, and doesn't
    // have to. With a context there, the server is connected whatever was
    // thrown, so a switch is what was asked for; and whatever stops the
    // orchestrator running a connect stops the switch the same way.
    test(
      'a StateError that is not the overlap still fails, from the switch',
      () async {
        final failure = StateError('ServerOrchestrator has been disposed.');
        final contexts = <ServerContext?>[null, _MockServerContext()];
        when(() => orchestrator.getContext('s1')).thenAnswer(
          (_) => contexts.length > 1 ? contexts.removeAt(0) : contexts.first,
        );
        when(
          () => orchestrator.connectServer('s1', makeActive: true),
        ).thenThrow(StateError('ServerOrchestrator has been disposed.'));
        when(() => orchestrator.switchActiveServer('s1')).thenThrow(failure);

        await expectLater(
          activateServer(orchestrator, 's1'),
          throwsA(same(failure)),
        );
      },
    );

    test(
      'a StateError from connecting with still no context is rethrown',
      () async {
        final failure = StateError('not a race');
        when(() => orchestrator.getContext('s1')).thenReturn(null);
        when(
          () => orchestrator.connectServer('s1', makeActive: true),
        ).thenThrow(failure);

        await expectLater(
          activateServer(orchestrator, 's1'),
          throwsA(same(failure)),
        );
        verifyNever(() => orchestrator.switchActiveServer(any()));
      },
    );
  });

  group('serverActivationFailureText', () {
    final l10n = ShellLocalizationsEn();

    test('capacity failures name the limit', () {
      final text = serverActivationFailureText(
        l10n,
        const ServerCapacityExceededException(
          currentConnected: 3,
          maxCapacity: 5,
        ),
        fallback: 'fallback',
      );

      // The count differs from the limit, so naming the wrong one fails.
      expect(text, contains('5'));
      expect(text, isNot(contains('3')));
      expect(text, isNot('fallback'));
    });

    test('other failures use the fallback', () {
      expect(
        serverActivationFailureText(
          l10n,
          StateError('x'),
          fallback: 'fallback',
        ),
        'fallback',
      );
    });
  });
}
