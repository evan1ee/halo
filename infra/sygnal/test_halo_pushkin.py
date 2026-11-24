"""Unit tests for Halo's Sygnal APNs pushkin (ADR-0015, D65, R-24)."""

from __future__ import annotations

import asyncio
import unittest
from types import SimpleNamespace

from halo_pushkin import (
    PRIORITY_ALERT,
    PRIORITY_BACKGROUND,
    PUSH_TYPE_ALERT,
    PUSH_TYPE_BACKGROUND,
    HaloApnsPushkin,
    apply_push_headers,
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

    def test_headers_follow_the_payload(self) -> None:
        silent = apply_push_headers(SimpleNamespace(message={"aps": {"content-available": 1}}, push_type="x", priority=10))
        self.assertEqual((silent.push_type, silent.priority), (PUSH_TYPE_BACKGROUND, 5))
        alert = apply_push_headers(
            SimpleNamespace(message={"aps": {"alert": {"body": "New message"}, "mutable-content": 1}}, push_type="x", priority=5)
        )
        self.assertEqual((alert.push_type, alert.priority), (PUSH_TYPE_ALERT, 10))

    def test_sygnal_hooks_build_halo_payloads(self) -> None:
        pushkin = HaloApnsPushkin()
        event = SimpleNamespace(event_id="$e", room_id="!r:x.org", counts=SimpleNamespace(unread=4))
        device = SimpleNamespace(data={"default_payload": {"aps": {"badge": 9, "alert": "New message"}}})
        payload = pushkin._get_payload_event_id_only(event, device.data["default_payload"])
        self.assertEqual((payload["event_id"], payload["room_id"]), ("$e", "!r:x.org"))
        self.assertNotIn("badge", payload["aps"])
        self.assertNotIn("unread_count", payload)
        count_only = SimpleNamespace(event_id=None, room_id=None, counts=SimpleNamespace(unread=4))
        self.assertEqual(pushkin._get_payload_full(count_only, device, None), {"aps": {"content-available": 1}})

    def test_sending_goes_through_sygnals_own_bridge(self) -> None:
        # Regression: awaiting aioapns directly on Twisted failed every push ("await wasn't used with future").
        sent: list[SimpleNamespace] = []

        class Base:
            async def _send_notification(self, request: SimpleNamespace) -> str:
                sent.append(request)
                return "ok"

        class Pushkin(HaloApnsPushkin, Base):
            pass

        request = SimpleNamespace(message={"aps": {"content-available": 1}}, push_type="alert", priority=10)
        self.assertEqual(asyncio.run(Pushkin()._send_notification(request)), "ok")
        self.assertEqual([(r.push_type, r.priority) for r in sent], [(PUSH_TYPE_BACKGROUND, 5)])
        self.assertNotIn("_dispatch_notification_unlimited", vars(HaloApnsPushkin))


if __name__ == "__main__":
    unittest.main()
