import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_household_invite_remote.dart';

void main() {
  late FakeHouseholdInviteRemote remote;
  final draft = HouseholdInviteDraft(invitee: InviteeEmail('a@b.c'));

  setUp(() => remote = FakeHouseholdInviteRemote());

  SendHouseholdInviteBloc build() =>
      SendHouseholdInviteBloc(householdId: 'hh_1', remote: remote);

  blocTest<SendHouseholdInviteBloc, SendHouseholdInviteState>(
    'sends the draft and hands back the invite',
    setUp: () => remote.onSend = (_, _) async => invite('i_1'),
    build: build,
    act: (bloc) => bloc.add(SendHouseholdInviteSubmitted(draft)),
    expect: () => [
      const SendHouseholdInviteSending(),
      SendHouseholdInviteSent(invite('i_1')),
    ],
    verify: (_) {
      expect(remote.calls, ['send(hh_1)']);
      expect(remote.sentDrafts.single, same(draft));
    },
  );

  test('a second submit while sending sends nothing', () async {
    final answer = Completer<HouseholdInvite>();
    remote.onSend = (_, _) => answer.future;
    final bloc = build();
    addTearDown(bloc.close);

    bloc
      ..add(SendHouseholdInviteSubmitted(draft))
      ..add(SendHouseholdInviteSubmitted(draft));
    await Future<void>.delayed(Duration.zero);
    answer.complete(invite('i_1'));
    await Future<void>.delayed(Duration.zero);

    expect(remote.calls, ['send(hh_1)']);
    expect(bloc.state, SendHouseholdInviteSent(invite('i_1')));
  });

  test('an edit retires a failure, and nothing else', () async {
    final error = refused(409);
    remote.onSend = (_, _) async => throw error;
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(const SendHouseholdInviteEdited());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state, const SendHouseholdInviteEditing());

    bloc.add(SendHouseholdInviteSubmitted(draft));
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state, SendHouseholdInviteFailed(error));

    bloc.add(const SendHouseholdInviteEdited());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state, const SendHouseholdInviteEditing());
  });

  group('the refresh after a refusal (#569)', () {
    late int refreshes;

    setUp(() => refreshes = 0);

    SendHouseholdInviteBloc refreshing({Future<void> Function()? onRefresh}) =>
        SendHouseholdInviteBloc(
          householdId: 'hh_1',
          remote: remote,
          onRefresh: onRefresh ?? () async => refreshes++,
        );

    blocTest<SendHouseholdInviteBloc, SendHouseholdInviteState>(
      'a 403 runs the refresh once',
      setUp: () => remote.onSend = (_, _) async => throw refused(403),
      build: refreshing,
      act: (bloc) => bloc.add(SendHouseholdInviteSubmitted(draft)),
      expect: () => [
        const SendHouseholdInviteSending(),
        isA<SendHouseholdInviteFailed>(),
      ],
      verify: (_) {
        expect(refreshes, 1);
        expect(remote.calls, ['send(hh_1)'], reason: 'never sent again');
      },
    );

    blocTest<SendHouseholdInviteBloc, SendHouseholdInviteState>(
      "a refusal that isn't a 403 doesn't refresh",
      setUp: () => remote.onSend = (_, _) async => throw refused(409),
      build: refreshing,
      act: (bloc) => bloc.add(SendHouseholdInviteSubmitted(draft)),
      expect: () => [
        const SendHouseholdInviteSending(),
        isA<SendHouseholdInviteFailed>(),
      ],
      verify: (_) => expect(refreshes, 0),
    );

    blocTest<SendHouseholdInviteBloc, SendHouseholdInviteState>(
      'a refresh that throws leaves the failure showing',
      setUp: () => remote.onSend = (_, _) async => throw refused(403),
      build: () =>
          refreshing(onRefresh: () async => throw StateError('refresh failed')),
      act: (bloc) => bloc.add(SendHouseholdInviteSubmitted(draft)),
      expect: () => [
        const SendHouseholdInviteSending(),
        isA<SendHouseholdInviteFailed>(),
      ],
      verify: (bloc) => expect(bloc.state, isA<SendHouseholdInviteFailed>()),
    );
  });

  test('a refusal can be fixed and sent again', () async {
    final error = refused(409);
    remote.onSend = (_, _) async => throw error;
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(SendHouseholdInviteSubmitted(draft));
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state, SendHouseholdInviteFailed(error));

    remote.onSend = (_, _) async => invite('i_1');
    bloc.add(SendHouseholdInviteSubmitted(draft));
    await Future<void>.delayed(Duration.zero);

    expect(remote.calls, ['send(hh_1)', 'send(hh_1)']);
    expect(bloc.state, SendHouseholdInviteSent(invite('i_1')));
  });
}
