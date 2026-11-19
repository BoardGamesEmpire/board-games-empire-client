import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/edit_event_bloc.dart';
import 'package:events/src/bloc/edit_event_state.dart';
import 'package:events/src/create/event_basics_section.dart';
import 'package:events/src/create/event_rules_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _onlineOnlyCopy = "Available when you're online";
const _savedCopy = 'Event saved.';
const _failedTitle = "Your changes weren't saved";
const _rulesNotSavedTitle = "The details were saved, but the rules weren't";
const _offlineCopy =
    "Couldn't reach the server. Check your connection and try again.";
const _refusedCopy =
    "You can't make these changes any more. Your role on this event may "
    'have changed.';
const _hostOnlyCopy = 'Only the host or a co-host can change the rules.';
const _hostOrHouseholdCopy =
    "Only the host, a co-host, or the household's owner or an admin can "
    'change the rules.';
const _unavailableCopy =
    "The rules can't be shown here, so they can't be changed.";
const _unknownCopy =
    "These rules use a setting this version of the app doesn't know, so "
    "they can't be changed here.";
const _notAllowedCopy = "You can't edit this event.";
const _notCachedCopy =
    "This event isn't on this device yet. Open it from your events, then "
    'edit it.';
const _rangeCopy = 'Enter a whole number from 51 to 100.';

final _at = DateTime.utc(2026, 11, 18);

/// Event `ev_1`: a strategy night for friends, with a description, a place
/// and a link, in [householdId] when one is given.
Event _event({String title = 'Game night', String? householdId}) => Event(
  id: 'ev_1',
  title: title,
  createdById: 'u_host',
  householdId: householdId,
  type: EventType.strategyNight,
  reach: Reach.friends,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  createdAt: _at,
  updatedAt: _at,
  description: 'Bring snacks',
  location: 'The back room',
  url: 'https://example.com/night',
);

/// `ev_1`'s rules: attendees vote, a 75% share of the votes, a 40% turnout
/// and two days to vote, unless a test says otherwise.
EventPolicy _policy({
  GameAdditionMode mode = GameAdditionMode.requiresVote,
  VoteThresholdType threshold = VoteThresholdType.supermajority,
  int? thresholdValue = 75,
}) => EventPolicy(
  id: 'p_1',
  eventId: 'ev_1',
  allowMemberInvites: true,
  allowGuestInvites: false,
  restrictToGameCategories: false,
  requireHostApprovalToJoin: false,
  allowSpectators: false,
  strictCapacity: false,
  gameAdditionMode: mode,
  restrictToAttendeePool: false,
  voteThresholdType: threshold,
  voteThresholdValue: thresholdValue,
  voteQuorumType: VoteQuorumType.percentOfAttendees,
  voteQuorumValue: 40,
  votingWindowHours: 48,
  voteEligibility: VoteEligibility.allAttendees,
  interestedWeight: InterestedWeight.asAbstain,
  createdAt: _at,
  updatedAt: _at,
);

/// `ev_1` as the cache holds it, seen by a viewer holding [role] on it.
EventDetail _detail({
  Event? event,
  EventPolicy? policy,
  EventRole? role = EventRole.host,
}) => EventDetail(
  snapshot: EventSnapshot(
    event: event ?? _event(),
    occurrences: const [],
    policy: policy,
  ),
  attendance: role == null
      ? null
      : attendance(EventParticipationStatus.attending).copyWith(role: role),
);

/// The edit page (#500) end to end, over a mocked cache and a scripted
/// server: what it opens with, who may change what, what Save sends, and
/// how each answer ends.
///
/// Where the page goes when it leaves is not this seam's business: it calls
/// `onLeave`, and the shell turns that into a route change. Here that pops
/// the page, as the route beneath the detail does.
void main() {
  late _MockEventRepository repository;
  late FakeConnectivity connectivity;
  late Stream<ConnectivityState> connectivityStates;

  /// The session the page was opened in (#694).
  late FakeSessionLease lease;

  /// How many times the page left through `onLeave`.
  late int leaves;

  setUpAll(() {
    registerFallbackValue(_event());
    registerFallbackValue(_policy());
  });

  setUp(() {
    repository = _MockEventRepository();
    connectivity = FakeConnectivity();
    connectivityStates = connectivity.watch().asBroadcastStream();
    lease = FakeSessionLease();
    leaves = 0;
    when(() => repository.cacheEventRow(any())).thenAnswer((_) async => true);
    when(
      () => repository.cacheEventPolicy(any()),
    ).thenAnswer((_) async => true);
  });

  tearDown(() => connectivity.close());

  /// The cache answering [detail] first, or never answering at all unless
  /// it [answers].
  void cache(EventDetail? detail, {bool answers = true}) {
    when(() => repository.watchEvent(any())).thenAnswer(
      (_) => answers
          ? Stream.value(detail)
          : StreamController<EventDetail?>().stream,
    );
  }

  /// A server that answers each event edit with the event as it would hold
  /// it, and each rules edit with [policyAnswer], unless [event] or [policy]
  /// answer instead.
  FakeEventRemote serving({
    FutureOr<Event> Function(EventEditRequest request)? event,
    FutureOr<EventPolicy> Function(EventEditRequest request)? policy,
  }) => FakeEventRemote(
    (_) => throw UnimplementedError('the edit page reads no list'),
    eventEdited:
        event ??
        (request) => _event(title: request.update?.title ?? 'Game night'),
    policyEdited: policy ?? (_) => _policy(mode: GameAdditionMode.direct),
  );

  /// The page, pushed above a page of its own as the shell pushes it, so
  /// that leaving shows. [textScaler], when given, overrides the scale the
  /// view gives the app.
  Widget harness({
    required EventRemoteDataSource remote,
    String eventId = 'ev_1',
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    TextScaler? textScaler,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    // As the shell hosts it, above the navigator.
    builder: (context, child) => StreamBuilder<ConnectivityState>(
      stream: connectivityStates,
      initialData: connectivity.current,
      builder: (context, state) {
        final offline = state.data == ConnectivityState.offline;
        return BgeConnectivityScope(
          offline: offline,
          noticeShowing: offline,
          onlineOnlyReason: _onlineOnlyCopy,
          child: textScaler == null
              ? child!
              : MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: child!,
                ),
        );
      },
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => EditEventScreen(
                eventId: eventId,
                repository: repository,
                remote: remote,
                session: lease,
                householdRole: householdRole,
                onLeave: (context) {
                  leaves++;
                  Navigator.of(context).pop();
                },
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  /// Opens the page on what the cache holds.
  Future<void> open(
    WidgetTester tester, {
    FakeEventRemote? remote,
    String eventId = 'ev_1',
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    TextScaler? textScaler,
  }) async {
    await tester.pumpWidget(
      harness(
        remote: remote ?? serving(),
        eventId: eventId,
        householdRole: householdRole,
        textScaler: textScaler,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enterText(WidgetTester tester, Key field, String text) async {
    await reveal(tester, find.byKey(field));
    await tester.enterText(find.byKey(field), text);
    await tester.pumpAndSettle();
  }

  /// Opens the menu [field] and picks [option] from it.
  Future<void> choose(WidgetTester tester, Key field, String option) async {
    await reveal(tester, find.byKey(field));
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    // The menu's copy, above the field's own.
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> toggleRules(WidgetTester tester) async {
    final title = find.text('Advanced: rules');
    await reveal(tester, title);
    await tester.tap(title);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final button = find.byKey(EditEventScreen.saveKey);
    await reveal(tester, button);
    await tester.tap(button);
    await tester.pump();
  }

  Finder inSnackBar(String copy) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

  Finder inFailure(String copy) => find.descendant(
    of: find.byKey(EditEventScreen.failureKey),
    matching: find.text(copy),
  );

  /// [text] at or under the widget keyed [key]: a note's own `Text` carries
  /// its key.
  Finder shows(Key key, String text) => find.descendant(
    of: find.byKey(key),
    matching: find.text(text),
    matchRoot: true,
  );

  TextField textField(WidgetTester tester, Key field) =>
      tester.widget<TextField>(
        find.descendant(
          of: find.byKey(field),
          matching: find.byType(TextField),
        ),
      );

  BgeDropdownField<T> dropdown<T>(WidgetTester tester) =>
      tester.widget<BgeDropdownField<T>>(find.byType(BgeDropdownField<T>));

  BgeSubmitButton saveButton(WidgetTester tester) =>
      tester.widget<BgeSubmitButton>(find.byKey(EditEventScreen.saveKey));

  testWidgets("opens prefilled with the event's details and rules", (
    tester,
  ) async {
    cache(_detail(policy: _policy()));
    await open(tester);

    expect(find.text('Edit event'), findsOneWidget);
    expect(
      textField(tester, EventBasicsSection.titleKey).controller!.text,
      'Game night',
    );
    expect(
      textField(tester, EventBasicsSection.descriptionKey).controller!.text,
      'Bring snacks',
    );
    expect(
      textField(tester, EventBasicsSection.locationKey).controller!.text,
      'The back room',
    );
    expect(
      textField(tester, EventBasicsSection.urlKey).controller!.text,
      'https://example.com/night',
    );
    expect(shows(EventBasicsSection.typeKey, 'Strategy night'), findsOneWidget);
    expect(shows(EventBasicsSection.reachKey, 'Friends'), findsOneWidget);
    // The event can't move household here.
    expect(find.byKey(EventBasicsSection.householdKey), findsNothing);

    await toggleRules(tester);
    expect(
      shows(EventRulesSection.gameAdditionKey, 'Attendees vote'),
      findsOneWidget,
    );
    expect(
      shows(EventRulesSection.thresholdKey, 'A set share'),
      findsOneWidget,
    );
    expect(
      textField(tester, EventRulesSection.thresholdValueKey).controller!.text,
      '75',
    );
    expect(
      shows(EventRulesSection.quorumKey, 'A share of attendees'),
      findsOneWidget,
    );
    expect(
      textField(tester, EventRulesSection.quorumValueKey).controller!.text,
      '40',
    );
    expect(
      textField(tester, EventRulesSection.windowKey).controller!.text,
      '48',
    );
    // A host may change them: no note.
    expect(find.byKey(EventRulesSection.noteKey), findsNothing);
    expect(dropdown<GameAdditionMode>(tester).readOnly, isFalse);
  });

  testWidgets("a later cache change doesn't fill the form again", (
    tester,
  ) async {
    final changes = StreamController<EventDetail?>.broadcast();
    addTearDown(changes.close);
    when(() => repository.watchEvent(any())).thenAnswer((_) => changes.stream);
    await tester.pumpWidget(harness(remote: serving()));
    await tester.tap(find.text('open'));
    await tester.pump();
    changes.add(_detail(policy: _policy()));
    await tester.pumpAndSettle();

    changes.add(_detail(event: _event(title: 'Renamed elsewhere')));
    await tester.pumpAndSettle();

    expect(
      textField(tester, EventBasicsSection.titleKey).controller!.text,
      'Game night',
    );
  });

  testWidgets("a type and reach this app doesn't know show no choice and no "
      'hint, and are kept', (tester) async {
    final remote = serving();
    cache(
      _detail(
        event: _event().copyWith(type: EventType.unknown, reach: Reach.unknown),
        policy: _policy(),
      ),
    );
    await open(tester, remote: remote);

    // Empty, and no server default in their place: the event holds a value
    // the default would misname.
    expect(dropdown<EventType>(tester).hint, isNull);
    expect(dropdown<Reach>(tester).hint, isNull);
    // Each field draws its label and nothing else: an empty field's value
    // is drawn as empty text.
    for (final (field, label) in [
      (EventBasicsSection.typeKey, 'Type'),
      (EventBasicsSection.reachKey, 'Who can see it'),
    ]) {
      expect(
        [
          for (final text in tester.widgetList<Text>(
            find.descendant(of: find.byKey(field), matching: find.byType(Text)),
          ))
            if (text.data?.isNotEmpty ?? true) text.data,
        ],
        [label],
        reason: label,
      );
    }
    expect(find.text('Casual gathering'), findsNothing);
    expect(find.text('Friends'), findsNothing);

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();

    // Neither is sent, so the event keeps both.
    expect(remote.eventEdits.single.update, EventUpdate(title: 'Board night'));
    expect(leaves, 1);
  });

  testWidgets('Save after changing the title sends it and leaves with Event '
      'saved.', (tester) async {
    final remote = serving();
    cache(_detail(policy: _policy()));
    await open(tester, remote: remote);

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();

    expect(remote.eventEdits, hasLength(1));
    final sent = remote.eventEdits.single;
    expect(sent.call, 'event');
    expect(sent.id, 'ev_1');
    // Only what changed.
    expect(sent.update, EventUpdate(title: 'Board night'));
    expect(leaves, 1);
    expect(inSnackBar(_savedCopy), findsOneWidget);
    expect(find.byType(EditEventScreen), findsNothing);
  });

  testWidgets('Save with nothing changed leaves without a SnackBar', (
    tester,
  ) async {
    final remote = serving();
    cache(_detail(policy: _policy()));
    await open(tester, remote: remote);

    await save(tester);
    await tester.pumpAndSettle();

    expect(remote.eventEdits, isEmpty);
    expect(leaves, 1);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(EditEventScreen), findsNothing);
  });

  testWidgets('a blank title is not sent', (tester) async {
    final remote = serving();
    cache(_detail(policy: _policy()));
    await open(tester, remote: remote);

    await enterText(tester, EventBasicsSection.titleKey, '   ');
    await save(tester);
    await tester.pumpAndSettle();

    expect(remote.eventEdits, isEmpty);
    expect(leaves, 0);
    expect(find.text('Give the event a title.'), findsOneWidget);
  });

  testWidgets('an organizer sees the rules read-only with the host-only note', (
    tester,
  ) async {
    cache(_detail(policy: _policy(), role: EventRole.organizer));
    await open(tester);

    // Said while the rules are collapsed.
    expect(shows(EventRulesSection.noteKey, _hostOnlyCopy), findsOneWidget);

    // They still open, to be read.
    await toggleRules(tester);
    expect(
      textField(tester, EventRulesSection.thresholdValueKey).controller!.text,
      '75',
    );
    await tester.tap(find.byKey(EventRulesSection.gameAdditionKey));
    await tester.pumpAndSettle();
    // No menu opened: the choices not picked are nowhere on screen.
    expect(find.text('The host approves them'), findsNothing);
    expect(dropdown<GameAdditionMode>(tester).readOnly, isTrue);
    expect(dropdown<VoteThresholdType>(tester).readOnly, isTrue);
    expect(dropdown<VoteQuorumType>(tester).readOnly, isTrue);
    for (final key in [
      EventRulesSection.thresholdValueKey,
      EventRulesSection.quorumValueKey,
      EventRulesSection.windowKey,
    ]) {
      final field = textField(tester, key);
      expect(field.readOnly, isTrue, reason: '$key');
      // Read-only, not disabled (STYLE_GUIDE §4, §5).
      expect(field.enabled, isNot(isFalse), reason: '$key');
    }
    // The basics are theirs to change.
    expect(textField(tester, EventBasicsSection.titleKey).readOnly, isFalse);
  });

  testWidgets("an organizer saves a title over stored rules the form's own "
      'ranges refuse', (tester) async {
    // Held, so the page stays to be looked at once Save is pressed.
    final answer = Completer<Event>();
    final remote = serving(event: (_) => answer.future);
    // The server took a 40% share; the form's own range starts at 51.
    cache(
      _detail(
        policy: _policy(thresholdValue: 40),
        role: EventRole.organizer,
      ),
    );
    await open(tester, remote: remote);
    // Open, where an error on the share would show.
    await toggleRules(tester);
    expect(
      textField(tester, EventRulesSection.thresholdValueKey).controller!.text,
      '40',
    );

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pump();

    // Sent, and nothing said against the rule the organizer can't change.
    expect(remote.eventEdits, hasLength(1));
    expect(remote.eventEdits.single.call, 'event');
    expect(
      remote.eventEdits.single.update,
      EventUpdate(title: 'Board night'),
    );
    expect(find.byKey(EventRulesSection.thresholdValueKey), findsOneWidget);
    expect(find.text(_rangeCopy), findsNothing);

    answer.complete(_event(title: 'Board night'));
    await tester.pumpAndSettle();
    expect(leaves, 1);
  });

  testWidgets("a host saves a title over a stored rule the form's own "
      'ranges refuse', (tester) async {
    // Held, so the page stays to be looked at once Save is pressed.
    final answer = Completer<Event>();
    final remote = serving(event: (_) => answer.future);
    // The server took a 40% share; the form's own range starts at 51.
    cache(_detail(policy: _policy(thresholdValue: 40)));
    await open(tester, remote: remote);
    // Open, where an error on the share would show.
    await toggleRules(tester);
    final share = textField(tester, EventRulesSection.thresholdValueKey);
    expect(share.controller!.text, '40');
    // The host's to change, unlike an organizer's.
    expect(share.readOnly, isFalse);

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pump();

    // The share, left as stored, is no change: only the title is sent, and
    // nothing is said against the share.
    expect(remote.eventEdits, hasLength(1));
    expect(remote.eventEdits.single.call, 'event');
    expect(
      remote.eventEdits.single.update,
      EventUpdate(title: 'Board night'),
    );
    expect(find.byKey(EventRulesSection.thresholdValueKey), findsOneWidget);
    expect(find.text(_rangeCopy), findsNothing);

    answer.complete(_event(title: 'Board night'));
    await tester.pumpAndSettle();
    expect(leaves, 1);
  });

  testWidgets("a share the host types outside the form's ranges blocks Save "
      'until it is fixed', (tester) async {
    final remote = serving(policy: (_) => _policy(thresholdValue: 60));
    cache(_detail(policy: _policy()));
    await open(tester, remote: remote);
    await toggleRules(tester);
    await enterText(tester, EventRulesSection.thresholdValueKey, '40');

    await save(tester);
    await tester.pumpAndSettle();

    // Shown where it is fixed, and focused there.
    expect(remote.eventEdits, isEmpty);
    expect(leaves, 0);
    expect(find.text(_rangeCopy), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(EventRulesSection.thresholdValueKey),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );

    await enterText(tester, EventRulesSection.thresholdValueKey, '60');
    await save(tester);
    await tester.pumpAndSettle();

    expect(remote.eventEdits, hasLength(1));
    expect(remote.eventEdits.single.call, 'policy');
    expect(
      remote.eventEdits.single.policy,
      EventPolicyUpdate(voteThresholdValue: 60),
    );
    expect(leaves, 1);
  });

  testWidgets("a household admin edits a household event's rules", (
    tester,
  ) async {
    final remote = serving();
    final asked = <String>[];
    cache(
      _detail(
        event: _event(householdId: 'h_1'),
        policy: _policy(),
        role: null,
      ),
    );
    await open(
      tester,
      remote: remote,
      householdRole: (householdId) async {
        asked.add(householdId);
        return HouseholdRole.householdAdmin;
      },
    );

    expect(asked, ['h_1']);
    expect(find.byKey(EventRulesSection.noteKey), findsNothing);
    await toggleRules(tester);
    await choose(
      tester,
      EventRulesSection.gameAdditionKey,
      'Anyone attending adds them',
    );
    await save(tester);
    await tester.pumpAndSettle();

    expect(remote.eventEdits, hasLength(1));
    expect(remote.eventEdits.single.call, 'policy');
    expect(
      remote.eventEdits.single.policy,
      EventPolicyUpdate(gameAdditionMode: GameAdditionMode.direct),
    );
    expect(leaves, 1);
    expect(inSnackBar(_savedCopy), findsOneWidget);
  });

  testWidgets('an organizer on a household event is told who changes the '
      'rules', (tester) async {
    cache(
      _detail(
        event: _event(householdId: 'h_1'),
        policy: _policy(),
        role: EventRole.organizer,
      ),
    );
    await open(tester, householdRole: (_) async => null);

    expect(
      shows(EventRulesSection.noteKey, _hostOrHouseholdCopy),
      findsOneWidget,
    );
  });

  testWidgets("a household role that can't be read counts as none", (
    tester,
  ) async {
    cache(
      _detail(
        event: _event(householdId: 'h_1'),
        policy: _policy(),
        role: null,
      ),
    );
    await open(tester, householdRole: (_) async => throw StateError('locked'));

    expect(shows(EditEventScreen.notAllowedKey, _notAllowedCopy), findsOne);
  });

  testWidgets('a page closed before the cache answers asks for no household '
      'role', (tester) async {
    final answers = StreamController<EventDetail?>();
    addTearDown(answers.close);
    when(() => repository.watchEvent(any())).thenAnswer((_) => answers.stream);
    final asked = <String>[];
    await tester.pumpWidget(
      harness(
        remote: serving(),
        householdRole: (householdId) async {
          asked.add(householdId);
          return HouseholdRole.householdAdmin;
        },
      ),
    );
    await tester.tap(find.text('open'));
    // The spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EditEventScreen), findsNothing);

    answers.add(
      _detail(
        event: _event(householdId: 'h_1'),
        policy: _policy(),
        role: null,
      ),
    );
    await tester.pumpAndSettle();

    expect(asked, isEmpty);
  });

  testWidgets("no policy: the rules say they can't be shown", (tester) async {
    final remote = serving();
    cache(_detail());
    await open(tester, remote: remote);

    expect(find.byKey(EventRulesSection.tileKey), findsNothing);
    expect(find.text('Advanced: rules'), findsOneWidget);
    expect(shows(EditEventScreen.rulesNoteKey, _unavailableCopy), findsOne);

    // The details still save, and no rules go with them.
    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();
    expect(remote.eventEdits.map((request) => request.call), ['event']);
  });

  testWidgets("rules with a setting this app doesn't know say so", (
    tester,
  ) async {
    cache(_detail(policy: _policy(mode: GameAdditionMode.unknown)));
    await open(tester);

    expect(find.byKey(EventRulesSection.tileKey), findsNothing);
    expect(shows(EditEventScreen.rulesNoteKey, _unknownCopy), findsOne);
  });

  testWidgets('a viewer without edit gets the not-allowed page', (
    tester,
  ) async {
    cache(_detail(policy: _policy(), role: EventRole.participant));
    await open(tester);

    expect(shows(EditEventScreen.notAllowedKey, _notAllowedCopy), findsOne);
    expect(find.byKey(EditEventScreen.saveKey), findsNothing);

    await tester.tap(find.text('Back to the event'));
    await tester.pumpAndSettle();
    expect(leaves, 1);
    expect(find.byType(EditEventScreen), findsNothing);
  });

  testWidgets('an uncached event gets the not-cached page', (tester) async {
    cache(null);
    await open(tester);

    expect(shows(EditEventScreen.notCachedKey, _notCachedCopy), findsOne);
    expect(find.byKey(EditEventScreen.saveKey), findsNothing);

    await tester.tap(find.text('Back to the event'));
    await tester.pumpAndSettle();
    expect(leaves, 1);
  });

  testWidgets('opened on a local id a reconcile moved, it edits the event '
      'by the id it moved to', (tester) async {
    // The detail followed the move (#499); its route kept the local id.
    when(() => repository.reconciledEventId('ev_local')).thenReturn('ev_1');
    when(() => repository.watchEvent(any())).thenAnswer(
      (invocation) => Stream.value(
        invocation.positionalArguments.single == 'ev_1'
            ? _detail(policy: _policy())
            : null,
      ),
    );
    final remote = serving();
    await open(tester, remote: remote, eventId: 'ev_local');

    expect(find.byKey(EditEventScreen.notCachedKey), findsNothing);
    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();
    expect(remote.eventEdits.single.id, 'ev_1');
  });

  testWidgets('offline: Save is disabled and says why', (tester) async {
    connectivity.current = ConnectivityState.offline;
    cache(_detail(policy: _policy()));
    await open(tester);

    expect(saveButton(tester).onPressed, isNull);
    expect(find.text(_onlineOnlyCopy), findsOneWidget);
    // The page itself reads offline, from the cache.
    expect(textField(tester, EventBasicsSection.titleKey).readOnly, isFalse);

    connectivity.change(ConnectivityState.online);
    await tester.pumpAndSettle();

    expect(saveButton(tester).onPressed, isNotNull);
    expect(find.text(_onlineOnlyCopy), findsNothing);
  });

  testWidgets('nothing takes an edit while a save is on its way', (
    tester,
  ) async {
    final answer = Completer<Event>();
    cache(_detail(policy: _policy()));
    await open(tester, remote: serving(event: (_) => answer.future));

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pump();

    expect(find.text('Saving…'), findsOneWidget);
    expect(textField(tester, EventBasicsSection.titleKey).readOnly, isTrue);
    expect(dropdown<EventType>(tester).readOnly, isTrue);
    await toggleRulesWhileBusy(tester);
    expect(dropdown<GameAdditionMode>(tester).readOnly, isTrue);

    answer.complete(_event(title: 'Board night'));
    await tester.pumpAndSettle();
    expect(leaves, 1);
  });

  testWidgets('a refusal stays on the page, and an edit takes it down', (
    tester,
  ) async {
    cache(_detail(policy: _policy()));
    await open(
      tester,
      remote: serving(
        event: (_) => throw const EventWriteRefusedException(
          'no',
          statusCode: 403,
        ),
      ),
    );

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();

    expect(leaves, 0);
    expect(inFailure(_failedTitle), findsOneWidget);
    expect(inFailure(_refusedCopy), findsOneWidget);

    await enterText(tester, EventBasicsSection.titleKey, 'Board nights');
    expect(find.byKey(EditEventScreen.failureKey), findsNothing);
  });

  testWidgets('a partial save keeps the page with the rules-not-saved title', (
    tester,
  ) async {
    final remote = serving(
      policy: (_) => throw const EventRemoteTransientException('offline'),
    );
    cache(_detail(policy: _policy()));
    await open(tester, remote: remote);

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await toggleRules(tester);
    await choose(
      tester,
      EventRulesSection.gameAdditionKey,
      'Anyone attending adds them',
    );
    await save(tester);
    await tester.pumpAndSettle();

    expect(remote.eventEdits.map((request) => request.call), [
      'event',
      'policy',
    ]);
    expect(leaves, 0);
    expect(find.byType(SnackBar), findsNothing);
    expect(inFailure(_rulesNotSavedTitle), findsOneWidget);
    expect(inFailure(_offlineCopy), findsOneWidget);
    // The form stays as typed.
    expect(
      textField(tester, EventBasicsSection.titleKey).controller!.text,
      'Board night',
    );
  });

  testWidgets('a 404 leaves the page', (tester) async {
    cache(_detail(policy: _policy()));
    await open(
      tester,
      remote: serving(
        event: (_) => throw const EventRemoteNotFoundException(
          'gone',
          statusCode: 404,
        ),
      ),
    );

    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();

    expect(leaves, 1);
    expect(find.byType(EditEventScreen), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  // #464: the save outlives the page. Left before it lands, it still says
  // how it went, on the page beneath, and goes nowhere: the user already
  // has.
  group('left mid-save', () {
    late EditEventBloc bloc;

    /// Submits a changed title with its save held on [answer], then goes
    /// back to the page beneath.
    Future<void> saveThenLeave(
      WidgetTester tester,
      Completer<Event> answer,
    ) async {
      cache(_detail(policy: _policy()));
      await open(tester, remote: serving(event: (_) => answer.future));
      await enterText(tester, EventBasicsSection.titleKey, 'Board night');
      await save(tester);
      await tester.pump();
      bloc = BlocProvider.of<EditEventBloc>(
        tester.element(find.byKey(EventBasicsSection.titleKey)),
      );
      expect(bloc.state, isA<EditEventSaving>());

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EditEventScreen), findsNothing);
    }

    Future<bool> closed(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      return bloc.isClosed;
    }

    testWidgets('the save is still said, and nothing more', (tester) async {
      final answer = Completer<Event>();
      await saveThenLeave(tester, answer);
      // Kept for the save still on its way.
      expect(await closed(tester), isFalse);

      answer.complete(_event(title: 'Board night'));
      await tester.pumpAndSettle();

      expect(inSnackBar(_savedCopy), findsOneWidget);
      expect(leaves, 0);
      expect(find.text('open'), findsOneWidget);
      expect(await closed(tester), isTrue);
    });

    testWidgets('a failure is said by its title', (tester) async {
      final answer = Completer<Event>();
      await saveThenLeave(tester, answer);

      answer.completeError(const EventRemoteTransientException('offline'));
      await tester.pumpAndSettle();

      expect(inSnackBar(_failedTitle), findsOneWidget);
      expect(leaves, 0);
      expect(await closed(tester), isTrue);
    });

    testWidgets('nothing is said once the session has ended', (tester) async {
      final answer = Completer<Event>();
      await saveThenLeave(tester, answer);
      lease.isLive = false;

      answer.complete(_event(title: 'Board night'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(leaves, 0);
      expect(await closed(tester), isTrue);
    });

    // The popped route stays mounted through its exit, and its listener
    // hears a save that lands there: said once, as it would be once the
    // page had gone, and the page doesn't leave again (#464).
    for (final (name, fails, copy) in [
      ('lands', false, _savedCopy),
      ('fails', true, _failedTitle),
    ]) {
      testWidgets("a save that $name on the route's way out is said once, "
          'and goes nowhere', (tester) async {
        final answer = Completer<Event>();
        cache(_detail(policy: _policy()));
        await open(tester, remote: serving(event: (_) => answer.future));
        await enterText(tester, EventBasicsSection.titleKey, 'Board night');
        await save(tester);
        await tester.pump();
        bloc = BlocProvider.of<EditEventBloc>(
          tester.element(find.byKey(EventBasicsSection.titleKey)),
        );
        Navigator.of(
          tester.element(find.byKey(EventBasicsSection.titleKey)),
        ).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(EditEventScreen), findsOneWidget);

        if (fails) {
          answer.completeError(const EventRemoteTransientException('offline'));
        } else {
          answer.complete(_event(title: 'Board night'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        // Still on its way out.
        expect(find.byType(EditEventScreen), findsOneWidget);
        final said = {
          for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
            bar.key,
        };
        expect(said, hasLength(1));
        await tester.pumpAndSettle();

        expect(inSnackBar(copy), findsOneWidget);
        expect(leaves, 0);
        expect(find.text('open'), findsOneWidget);
        expect(await closed(tester), isTrue);
      });
    }
  });

  testWidgets('fits at 320dp wide at 2.0 text', (tester) async {
    useViewSize(tester, const Size(320, 568));
    cache(
      _detail(
        event: _event(householdId: 'h_1'),
        policy: _policy(),
        role: EventRole.organizer,
      ),
    );
    await open(
      tester,
      remote: serving(
        event: (_) => throw const EventWriteRefusedException(
          'no',
          statusCode: 403,
        ),
      ),
      householdRole: (_) async => null,
      textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
    );
    expect(tester.takeException(), isNull);

    // Each menu's choice lays out whole: a dense menu would squeeze it into
    // one line's height, which throws nothing.
    await toggleRules(tester);
    expect(tester.takeException(), isNull);
    for (final (field, choice) in [
      (EventBasicsSection.typeKey, 'Strategy night'),
      (EventBasicsSection.reachKey, 'Friends'),
      (EventRulesSection.gameAdditionKey, 'Attendees vote'),
      (EventRulesSection.thresholdKey, 'A set share'),
      (EventRulesSection.quorumKey, 'A share of attendees'),
    ]) {
      await reveal(tester, find.byKey(field));
      final text = tester.renderObject<RenderParagraph>(shows(field, choice));
      expect(
        text.size.height,
        greaterThanOrEqualTo(text.getMaxIntrinsicHeight(text.size.width)),
        reason: choice,
      );
    }

    // A refusal above Save.
    await enterText(tester, EventBasicsSection.titleKey, 'Board night');
    await save(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(EditEventScreen.failureKey), findsOneWidget);

    // Offline, with the reason under Save.
    connectivity.change(ConnectivityState.offline);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(_onlineOnlyCopy), findsOneWidget);
  });

  group('accessibility audit', () {
    Widget Function(ThemeData theme) build({
      Future<HouseholdRole?> Function(String householdId)? householdRole,
      FakeEventRemote? remote,
    }) =>
        (theme) => harness(
          remote: remote ?? serving(),
          householdRole: householdRole,
          theme: theme,
        );

    // The harness shows the page from a button, so the page is open only
    // once that is tapped.
    Future<void> show(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(EditEventScreen), findsOneWidget);
    }

    // The page runs several screens tall at 320dp × 2.0, and every scroll
    // position that shows its end leaves a field half under the top edge,
    // which Flutter's tap-target check fails at its clipped size, a limit of
    // the tool (`docs/design/ACCESSIBILITY_AUDIT.md` §3). So a state reached
    // by scrolling is audited in a view tall enough for the whole page.
    Future<void> wholePage(
      WidgetTester tester,
      Future<void> Function(WidgetTester) reach,
    ) async {
      await useWholePage(tester);
      await reach(tester);
      await tester.pumpAndSettle();
      expectWholePage(tester);
    }

    Future<void> openRules(WidgetTester tester) async {
      await show(tester);
      await toggleRules(tester);
    }

    group('a host', () {
      setUp(() => cache(_detail(policy: _policy())));

      auditScreen('ready', build: build(), arrange: show);

      auditScreen(
        'rules open, whole page',
        build: build(),
        arrange: (tester) => wholePage(tester, openRules),
      );

      auditScreen(
        'refused, whole page',
        build: build(
          remote: serving(
            event: (_) => throw const EventWriteRefusedException(
              'no',
              statusCode: 403,
            ),
          ),
        ),
        arrange: (tester) => wholePage(tester, (tester) async {
          await show(tester);
          await enterText(tester, EventBasicsSection.titleKey, 'Board night');
          await save(tester);
          await tester.pumpAndSettle();
          expect(find.byKey(EditEventScreen.failureKey), findsOneWidget);
        }),
      );

      // Refused by the form, not the server: the error shows under its
      // field.
      auditScreen(
        'a rule out of range, whole page',
        build: build(),
        arrange: (tester) => wholePage(tester, (tester) async {
          await openRules(tester);
          await enterText(tester, EventRulesSection.thresholdValueKey, '40');
          await save(tester);
          await tester.pumpAndSettle();
          expect(find.text(_rangeCopy), findsOneWidget);
        }),
      );
    });

    group('an organizer on a household event', () {
      setUp(
        () => cache(
          _detail(
            event: _event(householdId: 'h_1'),
            policy: _policy(),
            role: EventRole.organizer,
          ),
        ),
      );

      auditScreen(
        'read-only rules open, whole page',
        build: build(householdRole: (_) async => null),
        arrange: (tester) => wholePage(tester, openRules),
      );
    });

    group('no policy', () {
      setUp(() => cache(_detail()));

      auditScreen(
        'rules unavailable, whole page',
        build: build(),
        arrange: (tester) => wholePage(tester, show),
      );
    });

    group('a participant', () {
      setUp(() => cache(_detail(role: EventRole.participant)));

      auditScreen('not allowed', build: build(), arrange: show);
    });

    group('an event not on this device', () {
      setUp(() => cache(null));

      auditScreen('not cached', build: build(), arrange: show);
    });

    group('the cache', () {
      setUp(() => cache(null, answers: false));

      // The spinner never settles.
      auditScreen(
        'loading',
        build: build(),
        arrange: (tester) async {
          await tester.tap(find.text('open'));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
        },
        settle: false,
      );
    });
  });
}

/// Opens the rules without settling, for a page whose Save spins.
Future<void> toggleRulesWhileBusy(WidgetTester tester) async {
  final title = find.text('Advanced: rules');
  await tester.ensureVisible(title);
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(title);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}
