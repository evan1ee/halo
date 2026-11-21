#!/usr/bin/env python3
"""Posts a location, a poll, a reply and a read receipt into the dev timeline fixture room, so those rows can be checked on screen.

Needs the fixtures from create-fixtures.py (reads ~/.config/halo-dev/contract.env; prints no credentials). The room is shared with
the contract tests, which only look for their own events, but run this on a throwaway dev server."""
import importlib.util, os, time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fixtures", os.path.join(HERE, "create-fixtures.py"))
fx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fx)


def main():
    values = fx.read_env()
    room = values[fx.P + "TIMELINE_ROOM"]
    me = fx.login(values[fx.P + "USER"], values[fx.P + "PASSWORD"])
    peer = fx.login(values[fx.P + "PEER_USER"], values[fx.P + "PEER_PASSWORD"])
    first = fx.send(peer, room, {"msgtype": "m.text", "body": "Original message to reply to"})
    fx.send(peer, room, {"msgtype": "m.text", "body": "Replying to the original",
                         "m.relates_to": {"m.in_reply_to": {"event_id": first}}})
    fx.send(peer, room, {"msgtype": "m.location", "body": "Brandenburg Gate", "geo_uri": "geo:52.5163,13.3777"})
    fx.send(peer, room, {
        "org.matrix.msc3381.poll.start": {
            "kind": "org.matrix.msc3381.poll.disclosed", "max_selections": 1,
            "question": {"org.matrix.msc1767.text": "Lunch?"},
            "answers": [{"id": "pizza", "org.matrix.msc1767.text": "Pizza"}, {"id": "soup", "org.matrix.msc1767.text": "Soup"}]},
        "org.matrix.msc1767.text": "Lunch?\n1. Pizza\n2. Soup"}, etype="org.matrix.msc3381.poll.start")
    mine = fx.send(me, room, {"msgtype": "m.text", "body": "Seen check from the app user"})
    time.sleep(1)
    fx.call("POST", f"/_matrix/client/v3/rooms/{room}/receipt/m.read/{mine}", {}, peer)
    print("sent sample events to", room)


if __name__ == "__main__":
    main()
