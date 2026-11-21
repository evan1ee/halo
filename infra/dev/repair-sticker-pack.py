#!/usr/bin/env python3
"""Re-uploads any image of the dev sticker pack "cats" whose media is missing on the server (the pack then shows
"couldn't be loaded" tiles). Uses the fixtures from create-fixtures.py. Idempotent: images that download are left alone."""
import importlib.util, os, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fixtures", os.path.join(HERE, "create-fixtures.py"))
fx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fx)

COLOURS = [(255, 120, 160), (120, 200, 255), (160, 230, 120), (255, 200, 0)]


def downloads(token, uri):
    server, media = uri[len("mxc://"):].split("/", 1)
    req = urllib.request.Request(f"{fx.SERVER}/_matrix/client/v1/media/download/{server}/{media}")
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return len(r.read()) > 0
    except urllib.error.HTTPError:
        return False


def main():
    values = fx.read_env()
    token = fx.login(values[fx.P + "USER"], values[fx.P + "PASSWORD"])
    room = values[fx.P + "STICKER_ROOM"]
    path = f"/_matrix/client/v3/rooms/{room}/state/m.room.image_pack/cats"
    pack = fx.call("GET", path, token=token)
    repaired = []
    for i, (name, image) in enumerate(sorted(pack.get("images", {}).items())):
        if image.get("url", "").startswith("mxc://") and downloads(token, image["url"]):
            continue
        data = fx.png(128, 128, COLOURS[i % len(COLOURS)])
        image["url"] = fx.upload(token, data, name + ".png")
        image["info"] = {"mimetype": "image/png", "w": 128, "h": 128, "size": len(data)}
        repaired.append(name)
    if repaired:
        fx.call("PUT", path, pack, token)
    print("repaired:", ", ".join(repaired) if repaired else "nothing (every image downloads)")


if __name__ == "__main__":
    main()
