# Board Games Empire — Client

The Flutter client for self-hosted BGE servers. This glossary defines the terms the
domain uses, so the same word means the same thing in code, issues and conversation.

Glossary only. Architecture lives in `docs/ROADMAP.md`. Decisions live on their issues,
or as ADRs in `docs/adr/` when they bind beyond one issue (see `docs/agents/domain.md`).

## Language

### Households

**Household**:
A named group of users who share games with each other. Owned by the user who created
it. Membership is explicit — there is no implicit or inherited household.
_Avoid_: Group, family, house, team

**Household Member**:
The record binding one user to one household, carrying their role and their
game-sharing preference. A user is a member or they are not; there is no partial or
pending membership outside an invitation.
_Avoid_: Participant, user (unqualified, in a household context)

**Household Role**:
A member's authority within one household — owner, admin, member or guest. Distinct
from a user's authority on the **server**, which is unrelated and does not confer
household authority.
_Avoid_: Permission, rank, access level

**Owner**:
The single member with ultimate authority over a household. Set at creation and
changed only by explicit transfer.
_Avoid_: Creator, admin

**Membership gate**:
The rule that a household's content is visible only to its members. A caller who
names a household they are not a member of receives the same answer as one naming a
household that does not exist.
_Avoid_: Auth check, permission check, filter

**Pool**:
The set of games a household's members have made available to that household. A
collection entry joins the pool only when its **visibility** is household-level, its
owner is sharing their collection with that household, and it has not been
individually excluded from it. All three, always.
_Avoid_: Household collection, household library, shared games, household inventory

**Games pool**:
The games an event's attendees have offered to bring to it, each one copy from the
offering attendee's own **collection**. It belongs to one event, not to a household,
and is unrelated to a household's **pool**: a game joins it only by being offered, and
leaves when it is taken back. Nominations for the event are made from it. The code calls
it the pool and its rows offered games.
_Avoid_: Pool (unqualified, in an event context), event collection, event library

**Excluded game**:
A single collection entry its owner has withheld from one specific household while
otherwise sharing with it.
_Avoid_: Hidden game, private game

### Collections and games

**Collection**:
The games one user owns, personally. Always belongs to exactly one user — a household
has a **pool**, never a collection.
_Avoid_: Library, inventory, shelf

**Collection entry**:
One user's ownership of one game on one platform, in one medium. Keyed by platform game
and medium, not by game alone: the same title owned physically and digitally, or on
Tabletop and on Steam, is two entries.
_Avoid_: Item, game (unqualified, when the ownership record is meant)

**Visibility**:
Who may see a thing beyond its owner. Six levels, widening: private, household,
friends, friends-of-friends, friends-of-households, public
(`packages/core/models/lib/src/domain/common/visibility.dart`).
Visibility is a *ceiling*, not a guarantee: household visibility still yields to the
owner's sharing preference and to exclusions.
_Avoid_: Privacy, sharing setting, permissions

**Recently added**:
The newest games a caller can see on the server, in the order `GET /games?sort=newest`
returns them, including hand-made and private ones.
_Avoid_: Recently imported, Import activity

### Sync

**Tombstone**:
A record marked deleted but retained, because deletion must survive a sync and because
re-adding the same thing restores its history rather than starting over.
_Avoid_: Soft delete (as a noun), archived, trashed

**Local-only**:
A record this device created that the server has not yet acknowledged. It is real to
its creator and invisible to everyone else until it syncs.
_Avoid_: Unsaved, draft, pending

**Dirty**:
A record with local changes the server has not yet accepted.
_Avoid_: Modified, stale, out of date

### Servers

**Server**:
One self-hosted BGE instance a user has connected to. Each carries its own identity,
users, households and games; nothing is shared between servers, including a user's
account.
_Avoid_: Instance, host, backend, tenant

**Active server**:
The one server the user is currently working in. Other connected servers remain
connected but inactive.
_Avoid_: Current server, selected server
