"""Unit tests for Halo's Sygnal APNs pushkin (ADR-0015, D65, R-24)."""

from __future__ import annotations

import unittest

from halo_pushkin import (
    PRIORITY_ALERT,
    PRIORITY_BACKGROUND,
    PUSH_TYPE_ALERT,
    PUSH_TYPE_BACKGROUND,
    HaloApnsPushkin,
    build_apns_envelope,
    is_count_only,
)


class HaloPushkinTests(unittest.TestCase):
    def test_synapse_count_only_notification_becomes_background_push_without_badge(self) -> None:
        # Exact Synapse v1.165 count-only fixture (SOURCES F-PUSH-1).
        notification = {
            "id": "",
            "type": None,
            "sender": "",
            "counts": {"unread": 7, "missed_calls": 1},
            "devices": [],
        }
        self.assertTrue(is_count_only(notification))

        envelope = build_apns_envelope(
            notification,
            default_payload={"aps": {"mutable-content": 1, "badge": 99, "alert": "New message"}},
        )
        self.assertEqual(envelope.push_type, PUSH_TYPE_BACKGROUND)
        self.assertEqual(envelope.priority, PRIORITY_BACKGROUND)
        self.assertEqual(envelope.payload, {"aps": {"content-available": 1}})
        self.assertNotIn("badge", envelope.payload["aps"])
        self.assertNotIn("unread_count", envelope.payload)
        self.assertNotIn("missed_calls", envelope.payload)
        self.assertNotIn("counts", envelope.payload)

    def test_event_id_only_notification_keeps_ids_and_strips_badge_and_counts(self) -> None:
        notification = {
            "event_id": "$ev123",
            "room_id": "!room:halo.localhost",
            "type": None,
            "counts": {"unread": 4},
        }
        self.assertFalse(is_count_only(notification))

        envelope = build_apns_envelope(
            notification,
            default_payload={
                "aps": {"mutable-content": 1, "badge": 4, "alert": {"body": "New message"}},
                "unread_count": 4,
                "missed_calls": 1,
                "counts": {"unread": 4},
            },
        )
        self.assertEqual(envelope.push_type, PUSH_TYPE_ALERT)
        self.assertEqual(envelope.priority, PRIORITY_ALERT)
        self.assertEqual(envelope.payload["event_id"], "$ev123")
        self.assertEqual(envelope.payload["room_id"], "!room:halo.localhost")
        self.assertEqual(envelope.payload["aps"]["mutable-content"], 1)
        self.assertNotIn("badge", envelope.payload["aps"])
        self.assertNotIn("unread_count", envelope.payload)
        self.assertNotIn("missed_calls", envelope.payload)
        self.assertNotIn("counts", envelope.payload)

    def test_default_payload_is_not_mutated(self) -> None:
        default_payload = {"aps": {"mutable-content": 1, "badge": 3}, "unread_count": 3}
        _ = build_apns_envelope(
            {"event_id": "$ev1", "room_id": "!r:x.org"},
            default_payload=default_payload,
        )
        self.assertEqual(default_payload["aps"]["badge"], 3)
        self.assertEqual(default_payload["unread_count"], 3)

    def test_pushkin_helper_handles_missing_default_payload(self) -> None:
        pushkin = HaloApnsPushkin()
        envelope = pushkin.build_halo_envelope(
            {"event_id": "$ev9", "room_id": "!room:x.org"},
            device_data=None,
        )
        self.assertEqual(envelope.push_type, PUSH_TYPE_ALERT)
        self.assertEqual(envelope.payload["aps"]["mutable-content"], 1)
        self.assertNotIn("badge", envelope.payload["aps"])
        self.assertEqual(envelope.payload["event_id"], "$ev9")
        self.assertEqual(envelope.payload["room_id"], "!room:x.org")


if __name__ == "__main__":
    unittest.main()
