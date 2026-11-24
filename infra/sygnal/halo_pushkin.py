"""Halo custom APNs pushkin for Sygnal (ADR-0015 Option 1, D65, R-24).

Pinned to Sygnal v0.15.1 (matrixdotorg/sygnal:v0.15.1).

Invariants (ADR-0015):
1. No push that reaches the device ever carries ``aps.badge``.
2. Server counts (``unread_count``, ``missed_calls``, ``counts``) are stripped
   from every payload.
3. Count-only notifications from Synapse (no ``event_id`` and no ``room_id``)
   are converted into silent background pushes (``aps.content-available = 1``,
   ``apns-push-type: background``, ``apns-priority: 5``) so iOS wakes Halo to
   reconcile from Matrix sync without touching the app icon badge.
4. Event notifications stay alert pushes (``apns-push-type: alert``,
   ``apns-priority: 10``) with ``aps.mutable-content = 1``, ``event_id``, and
   ``room_id`` so the NSE fetches the event via the SDK and recomputes the
   badge locally via ``BadgeCalculator``.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import Any, Mapping, MutableMapping

STRIPPED_TOP_LEVEL_KEYS = frozenset({"unread_count", "missed_calls", "counts"})

PUSH_TYPE_ALERT = "alert"
PUSH_TYPE_BACKGROUND = "background"
PRIORITY_ALERT = "10"
PRIORITY_BACKGROUND = "5"


@dataclass(frozen=True)
class ApnsEnvelope:
    """Resolved APNs payload and per-notification headers."""

    payload: dict[str, Any]
    push_type: str
    priority: str


def is_count_only(notification: Mapping[str, Any]) -> bool:
    """Return True when Synapse sent a badge/count-only notification."""
    event_id = notification.get("event_id") or notification.get("id") or ""
    room_id = notification.get("room_id") or ""
    return not str(event_id).strip() and not str(room_id).strip()


def sanitize_payload(payload: MutableMapping[str, Any]) -> dict[str, Any]:
    """Deep-copy and strip ``aps.badge`` and any server count fields."""
    cleaned: dict[str, Any] = copy.deepcopy(dict(payload))
    for key in STRIPPED_TOP_LEVEL_KEYS:
        cleaned.pop(key, None)

    aps = cleaned.get("aps")
    if isinstance(aps, dict):
        aps.pop("badge", None)
    else:
        cleaned["aps"] = {}
    return cleaned


def build_apns_envelope(
    notification: Mapping[str, Any],
    default_payload: Mapping[str, Any] | None = None,
) -> ApnsEnvelope:
    """Build an ADR-0015-compliant APNs payload + push_type + priority."""
    if is_count_only(notification):
        return ApnsEnvelope(
            payload={"aps": {"content-available": 1}},
            push_type=PUSH_TYPE_BACKGROUND,
            priority=PRIORITY_BACKGROUND,
        )

    base: dict[str, Any] = copy.deepcopy(dict(default_payload)) if default_payload else {}
    cleaned = sanitize_payload(base)
    aps = cleaned.setdefault("aps", {})
    aps["mutable-content"] = 1
    if "alert" not in aps:
        aps["alert"] = {"loc-key": "Notification"}

    event_id = notification.get("event_id") or notification.get("id")
    room_id = notification.get("room_id")
    if event_id:
        cleaned["event_id"] = str(event_id)
    if room_id:
        cleaned["room_id"] = str(room_id)

    return ApnsEnvelope(
        payload=sanitize_payload(cleaned),
        push_type=PUSH_TYPE_ALERT,
        priority=PRIORITY_ALERT,
    )


try:
    from aioapns import NotificationRequest, PushType  # type: ignore[import-not-found]
    from sygnal.apnspushkin import ApnsPushkin  # type: ignore[import-not-found]
    from sygnal.notifications import Device, Notification  # type: ignore[import-not-found]

    _SYGNAL_AVAILABLE = True
except ImportError:  # pragma: no cover - exercised in unit tests without Sygnal
    ApnsPushkin = object  # type: ignore[assignment,misc]
    NotificationRequest = None  # type: ignore[assignment]
    PushType = None  # type: ignore[assignment]
    Device = Any  # type: ignore[assignment]
    Notification = Any  # type: ignore[assignment]
    _SYGNAL_AVAILABLE = False


class HaloApnsPushkin(ApnsPushkin):  # type: ignore[valid-type,misc]
    """Sygnal APNs pushkin subclass enforcing ADR-0015 per notification.

    Configure in ``sygnal.yaml`` as::

        apps:
          one.mbm.halo:
            type: halo_pushkin.HaloApnsPushkin
            ...
    """

    def build_halo_envelope(
        self,
        notification: Mapping[str, Any],
        device_data: Mapping[str, Any] | None = None,
    ) -> ApnsEnvelope:
        default_payload = (device_data or {}).get("default_payload")
        if not isinstance(default_payload, Mapping):
            default_payload = None
        return build_apns_envelope(notification, default_payload=default_payload)

    async def _dispatch_notification_unlimited(
        self, n: Any, device: Any, context: Any
    ) -> list[str]:
        """Override Sygnal v0.15.1 APNs dispatch to choose push_type & priority per notification."""
        if not _SYGNAL_AVAILABLE:
            raise RuntimeError("Sygnal runtime is not installed in this environment.")

        raw_notification = {
            "id": getattr(n, "id", None),
            "event_id": getattr(n, "event_id", None),
            "room_id": getattr(n, "room_id", None),
            "type": getattr(n, "type", None),
            "counts": getattr(n, "counts", None),
        }
        envelope = self.build_halo_envelope(raw_notification, getattr(device, "data", None))

        pushkey = device.pushkey
        if getattr(self, "convert_device_token_to_hex", False):
            import base64

            pushkey = base64.b64decode(pushkey).hex()

        apns_push_type = (
            PushType.BACKGROUND
            if envelope.push_type == PUSH_TYPE_BACKGROUND
            else PushType.ALERT
        )
        request = NotificationRequest(
            device_token=pushkey,
            message=envelope.payload,
            push_type=apns_push_type,
            priority=envelope.priority,
        )
        response = await self.apns_client.send_notification(request)
        if not response.is_successful and response.description in {
            "BadDeviceToken",
            "Unregistered",
            "DeviceTokenNotForTopic",
        }:
            return [device.pushkey]
        return []
