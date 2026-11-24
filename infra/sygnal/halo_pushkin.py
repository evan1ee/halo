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


def is_background(payload: Mapping[str, Any]) -> bool:
    """A payload without an alert, sound or badge is a silent wake-up (APNs requires push type ``background``)."""
    aps = payload.get("aps")
    return isinstance(aps, Mapping) and "alert" not in aps and aps.get("content-available") == 1


def apply_push_headers(request: Any, *, alert: Any = PUSH_TYPE_ALERT, background: Any = PUSH_TYPE_BACKGROUND) -> Any:
    """Set ``apns-push-type`` and ``apns-priority`` per notification (Sygnal has one push type per app)."""
    if is_background(request.message):
        request.push_type = background
        request.priority = int(PRIORITY_BACKGROUND)
    else:
        request.push_type = alert
        request.priority = int(PRIORITY_ALERT)
    return request


try:
    from aioapns.common import PushType  # type: ignore[import-not-found]
    from sygnal.apnspushkin import ApnsPushkin  # type: ignore[import-not-found]

    _ALERT: Any = PushType.ALERT
    _BACKGROUND: Any = PushType.BACKGROUND
except ImportError:  # pragma: no cover - exercised in unit tests without Sygnal
    ApnsPushkin = object  # type: ignore[assignment,misc]
    _ALERT = PUSH_TYPE_ALERT
    _BACKGROUND = PUSH_TYPE_BACKGROUND


class HaloApnsPushkin(ApnsPushkin):  # type: ignore[valid-type,misc]
    """Sygnal APNs pushkin subclass enforcing ADR-0015 per notification.

    Only the payload and the per-notification headers are overridden. Connecting to APNs, retries, metrics and the
    classification of rejected tokens stay Sygnal's: aioapns runs on asyncio while Sygnal dispatches on Twisted, and
    only Sygnal's own ``_send_notification`` bridges the two (awaiting aioapns directly fails every send).

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

    @staticmethod
    def _ids(n: Any) -> dict[str, Any]:
        return {"event_id": getattr(n, "event_id", None), "room_id": getattr(n, "room_id", None)}

    def _get_payload_event_id_only(self, n: Any, default_payload: Mapping[str, Any]) -> dict[str, Any]:
        return build_apns_envelope(self._ids(n), default_payload=default_payload).payload

    def _get_payload_full(self, n: Any, device: Any, log: Any) -> dict[str, Any]:
        # Sygnal comes here for count-only notifications (no event) and for pushers without ``event_id_only``. Halo
        # never sends message content through the gateway, so both use the same envelope.
        return self.build_halo_envelope(self._ids(n), getattr(device, "data", None)).payload

    async def _send_notification(self, request: Any) -> Any:
        return await super()._send_notification(apply_push_headers(request, alert=_ALERT, background=_BACKGROUND))
