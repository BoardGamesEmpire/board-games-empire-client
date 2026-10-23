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
