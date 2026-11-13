import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_dates_section.dart';
import 'package:events/src/create/event_invitees_section.dart';
import 'package:events/src/create/event_rules_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import '../support/fake_user_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

/// What the repository hands back for a create: the local-only event, the
/// entry it queued, and the op as queued.
typedef _Created = ({
  Event event,
  String syncQueueId,
  CreateEventOperation operation,
});

/// The local-only event a create writes under [id].
Event _localEvent(String id) => Event(
  id: id,
  title: 'Game night',
  createdById: 'user-me',
  type: EventType.casualGathering,
  reach: Reach.friends,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  isDirty: true,
  isLocalOnly: true,
  createdAt: DateTime.utc(2026, 10, 26),
  updatedAt: DateTime.utc(2026, 10, 26),
);

Household _household(String id, String name) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026, 10),
  updatedAt: DateTime.utc(2026, 10),
);

final Household _home = _household('h_1', 'Home');
final Household _club = _household('h_2', 'Club');

const _ana = UserSummary(id: 'u_1', username: 'ana', displayName: 'Ana B');
const _bo = UserSummary(id: 'u_2', username: 'bo', displayName: 'Bo C');

/// The server refusing the create for an invitee it has no account for, as
/// the sender parks it.
SyncParked _unknownInvitee(String userId) => SyncParked(
  EventCreateRefusedException(
    'Event create failed with status 404',
    statusCode: 404,
    apiMessage: 'User with ID $userId not found',
  ),
);

/// The server refusing the create without saying who, as its 403 does.
const _refusedQuietly = SyncParked(
  EventCreateRefusedException(
    'Event create failed with status 403',
    statusCode: 403,
  ),
);

const _titleRequired = 'Give the event a title.';
const _linkInvalid = 'Enter a full link, starting with https://';
const _syncedCopy = 'Event created.';
const _queuedCopy = "Event saved. It'll be sent when you're back online.";

/// The heading of every banner a create that failed shows: some of their
/// messages give only a cause.
const _failedTitle = "Couldn't create the event";
const _refusedLateCopy =
    "The server didn't accept this event. It's saved on this device: review "
    'it from the home screen to try again or discard it.';
const _refusedCopy =
    "Someone you invited may not accept invites from you. Change who's "
    'invited and try again.';
const _refusedHouseholdCopy =
    'You may no longer be allowed to create events in this household. Pick '
    'another household, or none, and try again.';
const _refusedOtherCopy =
    "The server didn't accept it as it stands. Check the details and try "
    'again.';
const _errorCopy = "It couldn't be saved on this device. Try again.";

/// Pins the event create screen (#499) end to end over a mocked repository
/// and sender: the draft a filled-in form sends, the households it may
/// join, and what each outcome of the send shows.
///
/// Where the created event is shown is not this seam's business: the
/// screen hands its id to `onCreated`, and the shell turns that into a
/// route change.
void main() {
  // Local, as the pickers give it: Monday 26 October 2026, 6 PM.
  final now = DateTime(2026, 10, 26, 18);

  late _MockEventRepository repo;
  late _MockSyncOperationSender sender;
  late FakeUserRemote users;

  /// The session the screen was opened in (#694).
  late FakeSessionLease lease;

  /// Every create the repository answered, in order.
  late List<_Created> creates;

  /// The ids handed to `onCreated`, in order.
  late List<String> created;

  /// Answers a create as the repository does: `ev_local_1` under `q1`, then
  /// `ev_local_2` under `q2`.
  _Created answerCreate(Invocation invocation) {
    final n = creates.length + 1;
    final result = (
      event: _localEvent('ev_local_$n'),
      syncQueueId: 'q$n',
      operation: CreateEventOperation(
        localId: 'ev_local_$n',
        draft: invocation.positionalArguments.single as EventDraft,
      ),
    );
    creates.add(result);
    return result;
  }

  /// The drafts the repository was asked to create, in order.
  List<EventDraft> sent() => [for (final c in creates) c.operation.draft];

  setUpAll(() {
    registerFallbackValue(const EventDraft(title: 'x'));
    registerFallbackValue(
      const CreateEventOperation(
        localId: 'x',
        draft: EventDraft(title: 'x'),
      ),
    );
  });

  setUp(() {
    repo = _MockEventRepository();
    sender = _MockSyncOperationSender();
    users = FakeUserRemote()..onSearchUsers = (_) async => pageOf([_ana, _bo]);
    lease = FakeSessionLease();
    creates = [];
    created = [];

    when(() => repo.create(any()))
        .thenAnswer((invocation) async => answerCreate(invocation));
    when(() => repo.discardQueuedOp(any())).thenAnswer((_) async => true);
    // The common case: the sender delivers it, and the cache holds the
    // event under the server's id.
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered(eventId: 'ev_server'));
  });

  /// Answers each send with the next of [deliveries], in order.
  void stubDeliveries(List<SyncDelivery> deliveries) {
    final answers = [...deliveries];
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => answers.removeAt(0));
  }

  /// The screen, pushed above a page of its own as the shell pushes it, so
  /// that a screen leaving on its own would show. [textScaler], when given,
  /// overrides the scale the view gives the app.
  Widget harness({
    Stream<List<Household>>? households,
    String? householdId,
    TextScaler? textScaler,
    bool offline = false,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: const [
      ...EventsLocalizations.localizationsDelegates,
      UserSearchLocalizations.delegate,
    ],
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => BgeConnectivityScope(
      offline: offline,
      noticeShowing: offline,
      onlineOnlyReason: "Available when you're online",
      child: textScaler == null
          ? child!
          : MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => CreateEventScreen(
                repository: repo,
                sender: sender,
                users: users,
                session: lease,
                households: households,
                householdId: householdId,
                now: () => now,
                onCreated: (_, eventId) => created.add(eventId),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    Stream<List<Household>>? households,
    String? householdId,
    TextScaler? textScaler,
    bool offline = false,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      harness(
        households: households,
        householdId: householdId,
        textScaler: textScaler,
        offline: offline,
        theme: theme,
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
    await tester.pump();
  }

  /// Picks the first date's start, taking what each picker opens on: today
  /// at six.
  Future<void> pickStart(WidgetTester tester) async {
    final field = find.byKey(EventCreateDatesSection.startKey(0));
    await reveal(tester, field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  /// Fills in what a create needs: a title and when it starts.
  Future<void> fill(WidgetTester tester, {String title = 'Game night'}) async {
    await enterText(tester, CreateEventScreen.titleKey, title);
    await pickStart(tester);
  }

  /// Finds [user] through the search and picks them.
  Future<void> invite(WidgetTester tester, UserSummary user) async {
    await enterText(tester, EventInviteesSection.searchKey, user.username);
    // The search waits out its pause before it asks.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final row = find.byKey(EventInviteesSection.resultKey(user.id));
    await reveal(tester, row);
    await tester.tap(row);
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

  Future<void> submit(WidgetTester tester) async {
    final button = find.byKey(CreateEventScreen.submitKey);
    await reveal(tester, button);
    await tester.tap(button);
    await tester.pump();
  }

  /// Lets a create that succeeded land. Not a settle: the button spins
  /// until the route closes, and this harness's `onCreated` leaves it open.
  Future<void> landed(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Finder inSnackBar(String copy) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

  Finder inBanner(Key banner, String copy) =>
      find.descendant(of: find.byKey(banner), matching: find.text(copy));

  /// [name] as what the household picker shows.
  Finder pickerShows(String name) => find.descendant(
    of: find.byKey(CreateEventScreen.householdKey),
    matching: find.text(name),
  );

  BgeDropdownField<T> menu<T>(WidgetTester tester) =>
      tester.widget<BgeDropdownField<T>>(find.byType(BgeDropdownField<T>));

  TextField textField(WidgetTester tester, Key field) =>
      tester.widget<TextField>(
        find.descendant(
          of: find.byKey(field),
          matching: find.byType(TextField),
        ),
      );

  testWidgets('a blank title is not sent', (tester) async {
    await open(tester);
    await fill(tester, title: '   ');
    // Typing further down, so the title isn't where the user is.
    await enterText(tester, CreateEventScreen.locationKey, "Ana's place");

    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text(_titleRequired), findsOneWidget);
    verifyNever(() => repo.create(any()));
    // The refused submit goes back to it.
    expect(
      textField(tester, CreateEventScreen.titleKey).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets("a link that isn't a full http(s) URL is refused", (
    tester,
  ) async {
    await open(tester);
    await fill(tester);

    for (final link in [
      'example.com',
      'ftp://x.org',
      // The server's own check refuses these.
      'https://localhost',
      'https://my_site.com',
    ]) {
      await enterText(tester, CreateEventScreen.urlKey, link);
      await submit(tester);
      await tester.pumpAndSettle();

      expect(find.text(_linkInvalid), findsOneWidget, reason: link);
    }
    verifyNever(() => repo.create(any()));
  });

  testWidgets('a full link is sent as typed, trimmed', (tester) async {
    await open(tester);
    await fill(tester);
    await enterText(
      tester,
      CreateEventScreen.urlKey,
      '  https://example.com/night ',
    );

    await submit(tester);
    await landed(tester);

    expect(sent().single.url, 'https://example.com/night');
  });

  testWidgets('a valid form sends the draft it shows', (tester) async {
    await open(tester, households: Stream.value([_home, _club]));
    await enterText(tester, CreateEventScreen.titleKey, '  Game night ');
    await choose(tester, CreateEventScreen.householdKey, 'Club');
    await pickStart(tester);
    await invite(tester, _bo);

    await submit(tester);
    await landed(tester);

    final draft = sent().single;
    expect(
      draft,
      EventDraft(
        title: 'Game night',
        householdId: 'h_2',
        occurrences: [EventOccurrenceDraft(startDate: now.toUtc())],
        inviteUserIds: const ['u_2'],
      ),
    );
    expect(draft.occurrences.single.startDate!.isUtc, isTrue);
    // The rules are untouched, so the server's apply.
    expect(draft.policy, isNull);
  });

  testWidgets('create event stays enabled offline', (tester) async {
    await open(tester, offline: true);
    await fill(tester);

    // A create is queued, so it needs no connection (#49).
    final button = find.byKey(CreateEventScreen.submitKey);
    await reveal(tester, button);
    expect(tester.widget<BgeSubmitButton>(button).onPressed, isNotNull);
    expect(find.text("Available when you're online"), findsNothing);

    await submit(tester);
    await landed(tester);

    expect(sent().single.title, 'Game night');
  });

  testWidgets('type and who can see it start as the server has them, and '
      'offer only what it knows', (tester) async {
    await open(tester);

    // Untouched, each reads as the server's default. That each is left out
    // of the draft is 'a valid form sends the draft it shows', whose draft
    // has neither.
    expect(
      find.descendant(
        of: find.byKey(CreateEventScreen.typeKey),
        matching: find.text('Casual gathering'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(CreateEventScreen.reachKey),
        matching: find.text('Friends'),
      ),
      findsOneWidget,
    );
    expect(menu<EventType>(tester).items.map((item) => item.value), [
      for (final type in EventType.values)
        if (type != EventType.unknown) type,
    ]);
    // From the narrowest to the widest.
    expect(menu<Reach>(tester).items.map((item) => item.value), [
      Reach.private,
      Reach.friends,
      Reach.friendsOfFriends,
      Reach.public,
    ]);

    await choose(tester, CreateEventScreen.typeKey, 'Strategy night');
    await choose(tester, CreateEventScreen.reachKey, 'Public');
    await fill(tester);
    await submit(tester);
    await landed(tester);

    expect(
      (sent().single.type, sent().single.reach),
      (EventType.strategyNight, Reach.public),
    );
  });

  group('the household', () {
    testWidgets('a prefill the picker offers is chosen', (tester) async {
      await open(
        tester,
        households: Stream.value([_home, _club]),
        householdId: 'h_2',
      );

      expect(pickerShows('Club'), findsOneWidget);
      await fill(tester);
      await submit(tester);
      await landed(tester);

      expect(sent().single.householdId, 'h_2');
    });

    testWidgets('a prefill waits for a list that offers it', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      // A household the user's membership in isn't read yet, as on a link
      // opened before the first hydrate.
      await open(tester, households: households.stream, householdId: 'h_lodge');
      households.add([_home]);
      await tester.pumpAndSettle();
      expect(pickerShows('No household'), findsOneWidget);

      households.add([_home, _household('h_lodge', 'Lodge')]);
      await tester.pumpAndSettle();
      expect(pickerShows('Lodge'), findsOneWidget);

      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, 'h_lodge');
    });

    testWidgets("a prefill doesn't replace the user's own pick", (
      tester,
    ) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_lodge');
      households.add([_home, _club]);
      await tester.pumpAndSettle();
      await choose(tester, CreateEventScreen.householdKey, 'Club');
      await choose(tester, CreateEventScreen.householdKey, 'No household');

      households.add([_home, _club, _household('h_lodge', 'Lodge')]);
      await tester.pumpAndSettle();
      expect(pickerShows('No household'), findsOneWidget);

      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets("a prefill doesn't change the household a refused create "
        'was sent in', (tester) async {
      stubDeliveries([_refusedQuietly]);
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_lodge');
      households.add([_home]);
      await tester.pumpAndSettle();
      await fill(tester);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

      households.add([_home, _household('h_lodge', 'Lodge')]);
      await tester.pumpAndSettle();

      expect(pickerShows('No household'), findsOneWidget);
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);
    });

    testWidgets('a household that leaves the list is unpicked', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream);
      households.add([_home, _club]);
      await tester.pumpAndSettle();
      await choose(tester, CreateEventScreen.householdKey, 'Club');
      expect(pickerShows('Club'), findsOneWidget);

      // A later list drops it, as one read after the user's role in it
      // changed elsewhere would.
      households.add([_home]);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(pickerShows('No household'), findsOneWidget);
      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets('a pick made in a menu opened before the list dropped that '
        'household is not sent', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream);
      households.add([_home, _club]);
      await tester.pumpAndSettle();
      await fill(tester);
      final picker = find.byKey(CreateEventScreen.householdKey);
      await reveal(tester, picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(find.text('Club'), findsWidgets);

      // A later list drops Club while the menu is open.
      households.add([_home]);
      await tester.pumpAndSettle();

      // The menu went with the list it was opened on, so Club is nowhere
      // left to pick.
      expect(tester.takeException(), isNull);
      expect(find.text('Club'), findsNothing);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets('a submit before the households answer sends no household', (
      tester,
    ) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_1');

      // Drawn, with nothing to pick until they answer.
      expect(pickerShows('No household'), findsOneWidget);
      expect(menu<String?>(tester).readOnly, isTrue);

      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets('without households there is no picker, and a prefill is '
        'dropped', (tester) async {
      await open(tester, householdId: 'h_1');

      expect(find.byKey(CreateEventScreen.householdKey), findsNothing);
      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });
  });

  group('the outcome', () {
    testWidgets('a delivered create says so and calls onCreated with the '
        'server id', (tester) async {
      await open(tester);
      await fill(tester);

      await submit(tester);
      await landed(tester);

      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(created, ['ev_server']);
      verify(() => sender.deliver('q1', any())).called(1);
      // Where the event is shown is the caller's: the screen doesn't leave
      // on its own.
      expect(find.byType(CreateEventScreen), findsOneWidget);
    });

    testWidgets('a queued create says so and calls onCreated with the local '
        'id', (tester) async {
      stubDeliveries([
        SyncFailed(SyncFailure.unreachable, Exception('offline')),
      ]);
      await open(tester);
      await fill(tester);

      await submit(tester);
      await landed(tester);

      expect(inSnackBar(_queuedCopy), findsOneWidget);
      expect(inSnackBar(_syncedCopy), findsNothing);
      expect(created, ['ev_local_1']);
    });

    testWidgets('a refusal naming an invitee stays on the form and names '
        'them', (tester) async {
      stubDeliveries([_unknownInvitee('u_1')]);
      await open(tester);
      await fill(tester);
      await invite(tester, _ana);
      await invite(tester, _bo);

      await submit(tester);
      await tester.pumpAndSettle();

      // Under a heading that says what failed: the message gives only why.
      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(
        inBanner(
          CreateEventScreen.refusedKey,
          "Ana B can't be invited. Take them off and try again.",
        ),
        findsOneWidget,
      );
      expect(created, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      // Still the form, as it was sent.
      expect(
        find.byKey(EventInviteesSection.inviteeKey('u_1')),
        findsOneWidget,
      );
      expect(textField(tester, CreateEventScreen.titleKey).readOnly, isFalse);
    });

    testWidgets('a refusal naming no one stays on the form', (tester) async {
      stubDeliveries([_refusedQuietly]);
      await open(tester, households: Stream.value([_home]));
      await choose(tester, CreateEventScreen.householdKey, 'Home');
      await fill(tester);
      await invite(tester, _ana);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(inBanner(CreateEventScreen.refusedKey, _refusedCopy), findsOne);
      expect(created, isEmpty);

      // Any edit takes it down: it is about the form as it was sent.
      await enterText(tester, CreateEventScreen.titleKey, 'Game night 2');
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsNothing);
    });

    testWidgets('a refusal with no one invited points at the household', (
      tester,
    ) async {
      stubDeliveries([_refusedQuietly]);
      await open(tester, households: Stream.value([_home]), householdId: 'h_1');
      await fill(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedHouseholdCopy),
        findsOneWidget,
      );
      expect(created, isEmpty);
    });

    testWidgets('a refusal with no one invited and no household blames '
        'neither', (tester) async {
      stubDeliveries([_refusedQuietly]);
      await open(tester, households: Stream.value([_home]));
      await fill(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedOtherCopy),
        findsOneWidget,
      );
      expect(created, isEmpty);
    });

    testWidgets('taking the invitee off and creating again sends a new '
        'create', (tester) async {
      stubDeliveries([
        _unknownInvitee('u_1'),
        const SyncDelivered(eventId: 'ev_server'),
      ]);
      await open(tester);
      await fill(tester);
      await invite(tester, _ana);
      await invite(tester, _bo);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

      final remove = find.byTooltip('Remove Ana B');
      await reveal(tester, remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsNothing);

      await submit(tester);
      await landed(tester);

      // The refused create goes, then the form as it stands now is created
      // afresh.
      verifyInOrder([
        () => repo.create(any()),
        () => repo.discardQueuedOp('q1'),
        () => repo.create(any()),
      ]);
      expect(sent().map((draft) => draft.inviteUserIds), [
        ['u_1', 'u_2'],
        ['u_2'],
      ]);
      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(created, ['ev_server']);
    });

    testWidgets('a create that fails here says so above the submit', (
      tester,
    ) async {
      when(() => repo.create(any())).thenThrow(StateError('database locked'));
      await open(tester);
      await fill(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.errorKey, _failedTitle), findsOne);
      expect(inBanner(CreateEventScreen.errorKey, _errorCopy), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(created, isEmpty);
      final banner = tester.getRect(find.byKey(CreateEventScreen.errorKey));
      final button = tester.getRect(find.byKey(CreateEventScreen.submitKey));
      expect(banner.bottom, lessThan(button.top));

      await enterText(tester, CreateEventScreen.titleKey, 'Game night 2');
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.errorKey), findsNothing);
    });

    testWidgets('nothing takes an edit while a create is on its way', (
      tester,
    ) async {
      final delivery = Completer<SyncDelivery>();
      when(() => sender.deliver(any(), any()))
          .thenAnswer((_) => delivery.future);
      await open(tester, households: Stream.value([_home]));
      await fill(tester);

      await submit(tester);
      await tester.pump();

      expect(find.text('Creating…'), findsOneWidget);
      for (final field in [
        CreateEventScreen.titleKey,
        CreateEventScreen.descriptionKey,
        CreateEventScreen.locationKey,
        CreateEventScreen.urlKey,
      ]) {
        expect(textField(tester, field).readOnly, isTrue, reason: '$field');
      }
      expect(menu<String?>(tester).readOnly, isTrue);
      expect(menu<EventType>(tester).readOnly, isTrue);
      expect(menu<Reach>(tester).readOnly, isTrue);
      // And every section below the basics.
      expect(
        tester
            .widget<SegmentedButton<EventSchedulingMode>>(
              find.byKey(EventCreateDatesSection.modeKey),
            )
            .onSelectionChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(EventInviteesSection.searchKey))
            .readOnly,
        isTrue,
      );

      delivery.complete(const SyncDelivered(eventId: 'ev_server'));
      await landed(tester);
      expect(created, ['ev_server']);
      // Nor once it is done, with the form about to close.
      expect(textField(tester, CreateEventScreen.titleKey).readOnly, isTrue);
      expect(find.text('Creating…'), findsOneWidget);
    });

    testWidgets('a refusal is about the household it was sent in, though the '
        'list dropped it since', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      final delivery = Completer<SyncDelivery>();
      when(() => sender.deliver(any(), any()))
          .thenAnswer((_) => delivery.future);
      await open(tester, households: households.stream, householdId: 'h_1');
      households.add([_home]);
      await tester.pumpAndSettle();
      await fill(tester);
      await submit(tester);

      // The user's role in it changed elsewhere, so the server refuses the
      // create, and a list read since drops the household while the create
      // is on its way.
      households.add(const []);
      await tester.pump();
      delivery.complete(_refusedQuietly);
      await tester.pumpAndSettle();

      expect(pickerShows('No household'), findsOneWidget);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedHouseholdCopy),
        findsOneWidget,
      );
    });

    testWidgets('a refusal stays up when the list read after it drops the '
        'household', (tester) async {
      stubDeliveries([_refusedQuietly]);
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_1');
      households.add([_home]);
      await tester.pumpAndSettle();
      await fill(tester);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

      // The 403 reads the households again, and that list drops it. The
      // unpick is the form's, not an edit of the user's.
      households.add(const []);
      await tester.pumpAndSettle();

      expect(pickerShows('No household'), findsOneWidget);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedHouseholdCopy),
        findsOneWidget,
      );
    });

    // #464: the create outlives the form. Left before it lands, it still
    // says how it went, on the page beneath, and goes nowhere: the user
    // already has.
    group('left mid-create', () {
      late CreateEventBloc bloc;

      /// Holds each send on the completer this returns. Made in the test
      /// body, inside its fake async zone: one made in setUp completes
      /// outside it, where pumping never gets to it.
      Completer<SyncDelivery> holdSend() {
        final delivery = Completer<SyncDelivery>();
        when(() => sender.deliver(any(), any()))
            .thenAnswer((_) => delivery.future);
        return delivery;
      }

      /// Submits a filled-in form, with the create on its way.
      Future<void> submitHeld(WidgetTester tester) async {
        await open(tester);
        await fill(tester);
        await submit(tester);
        await tester.pump();
        bloc = BlocProvider.of<CreateEventBloc>(
          tester.element(find.byKey(CreateEventScreen.titleKey)),
        );
        expect(bloc.state, isA<CreateEventSubmitting>());
      }

      /// Submits a filled-in form, then goes back to the page beneath, and
      /// lets the form go, while the create is on its way.
      Future<void> submitThenLeave(WidgetTester tester) async {
        await submitHeld(tester);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(CreateEventScreen), findsNothing);
      }

      Future<bool> closed(WidgetTester tester) async {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        return bloc.isClosed;
      }

      /// The page beneath is the only route: nothing was pushed or popped
      /// after the user went back, and `onCreated` wasn't called.
      void expectStackUnchanged(WidgetTester tester) {
        expect(find.text('open'), findsOneWidget);
        expect(Navigator.of(tester.element(find.text('open'))).canPop(), false);
        expect(created, isEmpty);
      }

      testWidgets('left mid-create, the outcome is still said', (tester) async {
        final delivery = holdSend();
        await submitThenLeave(tester);
        // Kept for the create still on its way.
        expect(await closed(tester), isFalse);

        delivery.complete(const SyncDelivered(eventId: 'ev_server'));
        await tester.pumpAndSettle();

        expect(inSnackBar(_syncedCopy), findsOneWidget);
        expectStackUnchanged(tester);
        expect(await closed(tester), isTrue);
      });

      testWidgets('left mid-create, a create left queued says so', (
        tester,
      ) async {
        final delivery = holdSend();
        await submitThenLeave(tester);

        delivery.complete(
          SyncFailed(SyncFailure.unreachable, Exception('offline')),
        );
        await tester.pumpAndSettle();

        expect(inSnackBar(_queuedCopy), findsOneWidget);
        expectStackUnchanged(tester);
        expect(await closed(tester), isTrue);
      });

      testWidgets('left mid-create, a refusal is still said', (tester) async {
        final delivery = holdSend();
        await submitThenLeave(tester);

        delivery.complete(_refusedQuietly);
        await tester.pumpAndSettle();

        // Not the banner's heading: the refused event stays on the device,
        // so the bar says where to review it (#190).
        expect(inSnackBar(_refusedLateCopy), findsOneWidget);
        expect(inSnackBar(_failedTitle), findsNothing);
        expectStackUnchanged(tester);
        expect(await closed(tester), isTrue);
      });

      testWidgets('left mid-create, a failure here is still said', (
        tester,
      ) async {
        final create = Completer<_Created>();
        when(() => repo.create(any())).thenAnswer((_) => create.future);
        await submitThenLeave(tester);

        create.completeError(StateError('database locked'));
        await tester.pumpAndSettle();

        expect(inSnackBar(_failedTitle), findsOneWidget);
        expectStackUnchanged(tester);
        expect(await closed(tester), isTrue);
      });

      testWidgets('left mid-create, nothing is said once the session has '
          'ended', (tester) async {
        final delivery = holdSend();
        await submitThenLeave(tester);
        lease.isLive = false;

        delivery.complete(const SyncDelivered(eventId: 'ev_server'));
        await tester.pumpAndSettle();

        expect(find.byType(SnackBar), findsNothing);
        expectStackUnchanged(tester);
        // Still closed: ending the session skips the message, not the close.
        expect(await closed(tester), isTrue);
      });

      // The shell ends a session in the same turn it routes away, and the
      // popped route stays mounted through its exit. A create that settles
      // there asks the lease (#694), is said as it would be once the form
      // had gone, and goes nowhere (#464).
      group("on the route's way out", () {
        /// Submits a create held on its way: the write here when it [fails],
        /// else the send, which lands. Pops the form and, in the same turn
        /// when [endSession], ends the session, then pumps 50 ms into the
        /// exit. The returned function gives the answer and lets it reach the
        /// form, still inside the exit.
        Future<Future<void> Function()> submitThenPop(
          WidgetTester tester, {
          required bool fails,
          bool endSession = false,
        }) async {
          final create = Completer<_Created>();
          final delivery = holdSend();
          if (fails) {
            when(() => repo.create(any())).thenAnswer((_) => create.future);
          }
          await submitHeld(tester);
          Navigator.of(
            tester.element(find.byKey(CreateEventScreen.titleKey)),
          ).pop();
          if (endSession) lease.isLive = false;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(find.byType(CreateEventScreen), findsOneWidget);

          Future<void> answer() async {
            if (fails) {
              create.completeError(StateError('database locked'));
            } else {
              delivery.complete(const SyncDelivered(eventId: 'ev_server'));
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 50));
            expect(find.byType(CreateEventScreen), findsOneWidget);
          }

          return answer;
        }

        /// The keys of the bars showing: a bar said again is a new key.
        Set<Key?> barKeys(WidgetTester tester) => {
          for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
            bar.key,
        };

        for (final (name, fails) in [('lands', false), ('fails', true)]) {
          testWidgets('a create that $name after the session ended says '
              'nothing, and the bloc still closes', (tester) async {
            final answer = await submitThenPop(
              tester,
              fails: fails,
              endSession: true,
            );

            await answer();
            expect(find.byType(SnackBar), findsNothing);
            await tester.pumpAndSettle();

            expect(find.byType(SnackBar), findsNothing);
            expectStackUnchanged(tester);
            expect(await closed(tester), isTrue);
          });
        }

        for (final (name, fails, copy) in [
          ('lands', false, _syncedCopy),
          ('fails', true, _failedTitle),
        ]) {
          testWidgets('a create that $name is said once, and goes nowhere', (
            tester,
          ) async {
            final answer = await submitThenPop(tester, fails: fails);

            await answer();
            // One bar, drawn in both pages' scaffolds while the exit runs.
            expect(inSnackBar(copy), findsWidgets);
            final said = barKeys(tester);
            expect(said, hasLength(1));
            await tester.pumpAndSettle();

            expect(inSnackBar(copy), findsOneWidget);
            expect(barKeys(tester), said);
            expectStackUnchanged(tester);
            expect(await closed(tester), isTrue);
          });
        }
      });
    });
  });

  testWidgets('the form fits at 320dp wide at 2.0 text scale', (tester) async {
    useViewSize(tester, const Size(320, 568));
    stubDeliveries([_unknownInvitee('u_1')]);
    await open(
      tester,
      households: Stream.value([_home, _club]),
      householdId: 'h_2',
      textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
    );

    // Every error the basics and the dates can show, as after a refused
    // submit.
    await submit(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(_titleRequired), findsOneWidget);

    // Each menu's choice lays out whole: a dense menu would squeeze it into
    // one line's height, which throws nothing.
    for (final (field, choice) in [
      (CreateEventScreen.householdKey, 'Club'),
      (CreateEventScreen.typeKey, 'Casual gathering'),
      (CreateEventScreen.reachKey, 'Friends'),
    ]) {
      await reveal(tester, find.byKey(field));
      final text = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byKey(field), matching: find.text(choice)),
      );
      expect(
        text.size.height,
        greaterThanOrEqualTo(text.getMaxIntrinsicHeight(text.size.width)),
        reason: choice,
      );
    }

    // A refusal, with the rules open below it.
    await fill(tester);
    await invite(tester, _ana);
    await submit(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

    await reveal(tester, find.byKey(EventRulesSection.tileKey));
    await tester.tap(find.text('Advanced: rules'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('accessibility audit', () {
    Widget build(ThemeData theme) =>
        harness(households: Stream.value([_home, _club]), theme: theme);

    // The harness shows the screen from a button, so the page is open only
    // once that is tapped.
    Future<void> show(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateEventScreen), findsOneWidget);
    }

    Future<void> rejectBlankTitle(WidgetTester tester) async {
      await show(tester);
      await fill(tester, title: '   ');
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.text(_titleRequired), findsOneWidget);
    }

    Future<void> refuseInvitee(WidgetTester tester) async {
      stubDeliveries([_unknownInvitee('u_1')]);
      await show(tester);
      await fill(tester);
      await invite(tester, _ana);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);
    }

    Future<void> failCreate(WidgetTester tester) async {
      when(() => repo.create(any())).thenThrow(StateError('database locked'));
      await show(tester);
      await fill(tester);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.errorKey), findsOneWidget);
    }

    Future<void> submitInFlight(WidgetTester tester) async {
      final delivery = Completer<SyncDelivery>();
      addTearDown(() => delivery.complete(const SyncDelivered(eventId: 'e')));
      when(() => sender.deliver(any(), any()))
          .thenAnswer((_) => delivery.future);
      await show(tester);
      await fill(tester);
      await submit(tester);
      await tester.pump();
      expect(find.text('Creating…'), findsOneWidget);
    }

    // The form runs several screens tall at 320dp × 2.0, and every scroll
    // position that shows its end leaves a field half under the top edge,
    // which Flutter's tap-target check fails at its clipped size, a limit of
    // the tool (`docs/design/ACCESSIBILITY_AUDIT.md` §3). So each state is
    // audited at the top, as a user first sees it, and in a view tall enough
    // for the whole page.
    Future<void> wholePage(
      WidgetTester tester,
      Future<void> Function(WidgetTester) reach,
    ) async {
      await useWholePage(tester);
      await reach(tester);
      await tester.pumpAndSettle();
      expectWholePage(tester);
    }

    auditScreen('ready', build: build, arrange: show);

    auditScreen(
      'ready, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, show),
    );

    auditScreen('rejected submit', build: build, arrange: rejectBlankTitle);

    auditScreen(
      'rejected submit, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, rejectBlankTitle),
    );

    // No 'refused' call at the top: the sent form scrolls to the submit
    // button, and Flutter's tap-target check fails the field the scroll
    // leaves half under the top edge, the same limit of the tool. The
    // whole-page call below audits it.
    auditScreen(
      'refused, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, refuseInvitee),
    );

    auditScreen('failure', build: build, arrange: failCreate);

    auditScreen(
      'failure, whole page',
      build: build,
      arrange: (tester) => wholePage(tester, failCreate),
    );

    // The busy submit button spins, so the page never settles. The scheduling
    // mode's segments are disabled while the create is on its way; their
    // dimmed labels fail contrast, which WCAG 1.4.3 exempts for an inactive
    // control. A false finding: see `docs/design/ACCESSIBILITY_AUDIT.md` §3.
    auditScreen(
      'submitting, whole page',
      build: build,
      arrange: (tester) async {
        await useWholePage(tester);
        await submitInFlight(tester);
        expectWholePage(tester);
      },
      textContrast: false,
      settle: false,
    );
  });

  group('keyboard', () {
    late SemanticsHandle semantics;

    setUp(() => semantics = SemanticsBinding.instance.ensureSemantics());
    tearDown(() => semantics.dispose());

    /// The screen open, with the households answered, so the household picker
    /// is a stop as it is for a user who has some.
    Future<void> openForm(WidgetTester tester) =>
        open(tester, households: Stream.value([_home, _club]));

    /// The order the form reads in, top to bottom: the back button, the
    /// basics, the scheduling mode's three segments, when the first date
    /// starts and ends, the invitee search, the rules and the submit. A menu
    /// reads its label and what it shows; the rules read their title and the
    /// note under it.
    const readingOrder = [
      'Back',
      'Title',
      'Household\nNo household',
      'Type\nCasual gathering',
      'Who can see it\nFriends',
      'Description (optional)',
      'Location (optional)',
      'Link (optional)',
      'One date',
      'Several days',
      'Poll',
      'Starts',
      'Ends (optional)',
      'Search by name or username',
      "Advanced: rules\nRules can't be changed after the event is created.",
      'Create event',
    ];

    /// The field [key] holds, as `expectFocusReturnsAfterDialog` needs it:
    /// below the field's own focus node, so `Focus.of` finds that node.
    Finder whenField(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(InputDecorator),
    );

    /// Tabs to the [label] button in the open [dialog], and presses Enter.
    Future<void> pressInDialog(
      WidgetTester tester,
      Type dialog,
      String label,
    ) => activateByKeyboard(
      tester,
      find.descendant(of: find.byType(dialog), matching: find.text(label)),
    );

    /// Cancels the open date picker by keyboard.
    Future<void> cancelDate(WidgetTester tester) async {
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await pressInDialog(tester, DatePickerDialog, 'Cancel');
      expect(find.byType(DatePickerDialog), findsNothing);
    }

    /// Takes the open date picker's date by keyboard, then cancels the time
    /// picker that follows it.
    Future<void> cancelTime(WidgetTester tester) async {
      await pressInDialog(tester, DatePickerDialog, 'OK');
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await pressInDialog(tester, TimePickerDialog, 'Cancel');
      expect(find.byType(TimePickerDialog), findsNothing);
    }

    testWidgets('Tab follows reading order, Shift+Tab reverses it, and '
        'nothing traps focus', (tester) async {
      await openForm(tester);

      await expectTraversable(tester, expectedOrder: readingOrder);
    });

    for (final (name, key) in [
      ('start', EventCreateDatesSection.startKey(0)),
      ('end', EventCreateDatesSection.endKey(0)),
    ]) {
      testWidgets("the $name's date picker, cancelled, gives focus back to the "
          'field', (tester) async {
        await openForm(tester);

        await expectFocusReturnsAfterDialog(
          tester,
          opener: whenField(key),
          dismiss: () => cancelDate(tester),
        );
        expect(tester.widget<InputDecorator>(whenField(key)).isEmpty, isTrue);
      });

      testWidgets("the $name's time picker, cancelled, gives focus back to the "
          'field', (tester) async {
        await openForm(tester);

        await expectFocusReturnsAfterDialog(
          tester,
          opener: whenField(key),
          dismiss: () => cancelTime(tester),
        );
        // A date taken and its time cancelled leave the field as it was.
        expect(tester.widget<InputDecorator>(whenField(key)).isEmpty, isTrue);
      });
    }
  });
}
