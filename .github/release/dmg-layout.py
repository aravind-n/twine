"""Write or verify Finder layout on a mounted installer volume.

The background alias is created on the writable image before compression. Its
volume creation date and catalog ID survive conversion and let Finder resolve
it after download, even at a different mount point. No Finder session is needed.
"""

from pathlib import Path
import sys

from ds_store import DSStore
from mac_alias import Alias


verify = len(sys.argv) == 3 and sys.argv[1] == "--verify"
if len(sys.argv) != (3 if verify else 2):
    raise SystemExit("usage: dmg-layout.py [--verify] MOUNTED_VOLUME")
mount = Path(sys.argv[-1]).resolve()
image = mount / ".background.tiff"
background = Alias.for_file(str(image))

def text(value):
    return value.decode("utf-8") if isinstance(value, bytes) else value


if verify:
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        options = store["."]["icvp"]
        actual = Alias.from_bytes(options["backgroundImageAlias"])
        assert options["backgroundType"] == 2
        assert options["iconSize"] == 80.0
        assert store["Twine.app"]["Iloc"] == (130, 134)
        assert store["Applications"]["Iloc"] == (410, 134)
        assert text(actual.volume.name) == text(background.volume.name)
        assert actual.volume.creation_date == background.volume.creation_date
        assert actual.target.cnid == background.target.cnid
        assert text(actual.target.posix_path) == "/.background.tiff"
    print("Finder background resolves on the packaged volume")
    raise SystemExit(0)

with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["vstl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 160}, {540, 262}}",
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": background.to_bytes(),
        # Finder image backgrounds need explicit RGB components. Keep the
        # approved charcoal canvas in both system appearances.
        "backgroundColorRed": 41 / 255,
        "backgroundColorGreen": 42 / 255,
        "backgroundColorBlue": 43 / 255,
        "arrangeBy": "none",
        "iconSize": 80.0,
        "textSize": 13.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": False,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["Twine.app"]["Iloc"] = (130, 134)
    store["Applications"]["Iloc"] = (410, 134)
