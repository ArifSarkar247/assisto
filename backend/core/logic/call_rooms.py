"""
callsB — pure rules for GROUP calls on the current MESH (no Django).

A group call is a ROOM (the roster) over PAIR links: every two joined
people have their own CallRecord, i.e. their own peer connection, their own
signalling relay (call.signal per call_id) and their own relay-minute row in
the P&L. Up to MAX_PARTICIPANTS (4) people: with 4 each phone sends its
audio/video 3 times, which is the honest limit of a phone mesh on Bangladesh
mobile data. More than 4 needs an SFU (meetings plan) — not built here.

Member states:
  ringing   invited; the normal incoming-call ring is going (ring record)
  joined    in the call
  left      was in the call, left (can join again from the chat)
  declined | missed | busy | offline   the ring ended without joining
"""
from __future__ import annotations

MAX_PARTICIPANTS = 4

ACTIVE_STATES = ("ringing", "joined")
RING_OUTCOMES = {
    "declined": "declined",
    "busy": "busy",
    "offline": "offline",
    "no_answer": "missed",
    "canceled": "missed",
}

# add-person abuse guard (per inviter): a burst inside one call, and a
# rolling window across all calls.
INVITES_PER_ROOM_PER_MIN = 3
INVITES_PER_10_MIN = 10


def active_count(states):
    """How many roster rows take a seat (ringing or joined)."""
    return sum(1 for s in states if s in ACTIVE_STATES)


def has_seat(states, cap=MAX_PARTICIPANTS):
    """Can one more person be invited / join?"""
    return active_count(states) < int(cap or MAX_PARTICIPANTS)


def ring_outcome(end_reason):
    """Roster state for a ring record that ended before it was answered."""
    return RING_OUTCOMES.get(str(end_reason or ""), "missed")


def invite_verdict(*, inviter_joined, room_live, states, target_state,
                   accepted_contact, blocked, cap=MAX_PARTICIPANTS,
                   recent_room_invites=0, recent_invites=0):
    """Why an add-person request is refused, or "ok".

      not_in_call     the inviter is not (or no longer) in the call
      ended           the room ended
      not_contact     only ACCEPTED My Circle contacts can be added
      blocked         either side blocked the other (neutral to the user)
      already_in      the person is ringing / already in the call
      full            MAX_PARTICIPANTS seats taken
      rate_limited    too many invites in a short time
    """
    if not room_live:
        return "ended"
    if not inviter_joined:
        return "not_in_call"
    if not accepted_contact:
        return "not_contact"
    if blocked:
        return "blocked"
    if target_state in ACTIVE_STATES:
        return "already_in"
    if not has_seat(states, cap):
        return "full"
    if (recent_room_invites >= INVITES_PER_ROOM_PER_MIN
            or recent_invites >= INVITES_PER_10_MIN):
        return "rate_limited"
    return "ok"


def join_verdict(*, room_live, my_state, allowed, states,
                 cap=MAX_PARTICIPANTS):
    """Can this person join the ongoing call (e.g. "Join call" in the
    group chat)? -> "ok" | "joined" (already in) | "ended" | "forbidden" |
    "full"."""
    if not room_live:
        return "ended"
    if my_state == "joined":
        return "joined"
    if not allowed:
        return "forbidden"
    # a ringing invitee who joins from the chat takes the seat it holds
    seats = list(states)
    if my_state == "ringing":
        seats.remove("ringing")
    if not has_seat(seats, cap):
        return "full"
    return "ok"


def should_end(states):
    """The room ends when nobody is left to talk to: no one joined, or one
    person joined with no one still ringing."""
    joined = sum(1 for s in states if s == "joined")
    ringing = sum(1 for s in states if s == "ringing")
    return joined == 0 or (joined == 1 and ringing == 0)


def mesh_pairs(joiner_id, joined_ids, linked_ids):
    """New pair links when `joiner_id` joins: one to every joined person it
    has no live link with yet. The JOINER is the caller (= the offerer), so
    two phones never both send an offer for the same pair."""
    out = []
    for uid in joined_ids:
        if uid == joiner_id or uid in linked_ids:
            continue
        out.append((joiner_id, uid))
    return out


def low_bandwidth(participants):
    """3-4 people: every phone sends its video 2-3 times — lower the video
    resolution / frame rate (the app reads this flag from the roster)."""
    return int(participants) >= 3
