#!/usr/bin/env python3
"""Adds an animated GIF sticker ("spin") to the dev sticker pack "cats", so grid autoplay can be checked on screen.

Needs Pillow (python3 -m pip install pillow) and the fixtures from create-fixtures.py. Idempotent."""
import importlib.util, io, os, sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fixtures", os.path.join(HERE, "create-fixtures.py"))
fx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fx)


def gif():
    frames = []
    for i in range(12):
        image = Image.new("RGB", (128, 128), (20, 20, 60))
        draw = ImageDraw.Draw(image)
        x = 10 + i * 9
        draw.ellipse((x, 44, x + 40, 84), fill=(255, 200, 0))
        frames.append(image)
    out = io.BytesIO()
    frames[0].save(out, format="GIF", save_all=True, append_images=frames[1:], duration=80, loop=0)
    return out.getvalue()


def main():
    values = fx.read_env()
    token = fx.login(values[fx.P + "USER"], values[fx.P + "PASSWORD"])
    room = values[fx.P + "STICKER_ROOM"]
    data = gif()
    uri = fx.call("POST", "/_matrix/media/v3/upload?filename=spin.gif", token=token, raw=data, ctype="image/gif")["content_uri"]
    path = f"/_matrix/client/v3/rooms/{room}/state/m.room.image_pack/cats"
    pack = fx.call("GET", path, token=token)
    pack.setdefault("images", {})["spin"] = {
        "url": uri, "body": "Spinning", "usage": ["sticker"],
        "info": {"mimetype": "image/gif", "w": 128, "h": 128, "size": len(data)}}
    fx.call("PUT", path, pack, token)
    print("added spin.gif", len(data), "bytes to", room)


if __name__ == "__main__":
    main()
