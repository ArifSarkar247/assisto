"""group-calls — pure rules for My Circle group calls (no Django imports).

MESH: every pair of people in a group call is one normal 1:1 CallRecord (a
"leg"). The record's CALLER always sends the WebRTC offer for that leg, so
both phones agree without negotiating roles. A newcomer is the caller of
every leg it opens, so it offers to everyone already in the call.

Data (per person, N = people in the call; upload ~= download):
  audio  Opus ~32 kbps x (N-1)           -> 4 people ~1.4 MB/min, 8 ~3.4 MB/min
  video  240p ~150 kbps (+audio) x (N-1)  -> 4 people ~8 MB/min
         5+ people: 120p ~80 kbps per leg (VIDEO_KBPS_MANY)
"""
from __future__ import annotations

MAX_PEOPLE = 8

# member seat states that hold one of the MAX_PEOPLE places
SEAT_STATES = ("ringing", "joined")
END_STATES = ("left", "declined", "missed")

AUDIO_KBPS = 32
VIDEO_KBPS = 150
VIDEO_KBPS_MANY = 80
MANY_PEOPLE = 5      # from this many people video drops to VIDEO_KBPS_MANY

# a joined phone that has not polled for this long has left the call
MEMBER_STALE_S = 40


def seats_taken(states):
    """How many of the MAX_PEOPLE places are held (ringing + joined)."""
    return sum(1 for s in states if s in SEAT_STATES)


def free_seats(states):
    return max(0, MAX_PEOPLE - seats_taken(states))


def split_invites(candidate_ids, states):
    """(to_ring, refused_full) for a list of user ids, keeping order and
    never more than the free places."""
    free = free_seats(states)
    seen, ring, full = set(), [], []
    for uid in candidate_ids:
        if uid in seen:
            continue
        seen.add(uid)
        if len(ring) < free:
            ring.append(uid)
        else:
            full.append(uid)
    return ring, full


def room_should_end(joined, ringing):
    """The call ends when at most one person is in it and nobody is still
    being rung (a host alone while others ring keeps waiting)."""
    return joined <= 1 and ringing == 0 or joined == 0


def member_state_for_ring(ring_state, end_reason):
    """A ringing member's seat state from its ring record. None = unchanged."""
    if ring_state in ("connecting", "active", "reconnecting"):
        return "joined"
    if ring_state == "ringing":
        return None
    if end_reason in ("declined", "busy"):
        return "declined"
    return "missed"


def pair_key(a, b):
    return (a, b) if a <= b else (b, a)


def legs_needed(me, joined_ids, existing_pairs):
    """Peers `me` still needs a live leg with (sorted, never `me`)."""
    have = set(existing_pairs)
    return sorted(u for u in set(joined_ids)
                  if u != me and pair_key(me, u) not in have)


def is_offerer(user_id, caller_id):
    return user_id == caller_id


def video_kbps(people):
    return VIDEO_KBPS_MANY if people >= MANY_PEOPLE else VIDEO_KBPS


def data_mb_per_min(people, video=False):
    """Approximate upload+download MB per minute for one person."""
    peers = max(0, people - 1)
    kbps = AUDIO_KBPS + (video_kbps(people) if video else 0)
    return round(2 * kbps * peers * 60 / 8 / 1000, 1)


FULL_BN = "এই কলে সর্বোচ্চ ৮ জন থাকতে পারেন। কলটি এখন পূর্ণ।"
FULL_EN = "A call can have at most 8 people. This call is full."
