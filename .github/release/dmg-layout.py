"""Regenerate Finder.DS_Store when changing the installer layout.

Maintenance only: install ds_store==1.3.1 in a temporary virtual environment,
then run this script. Release builds copy the committed template and do not
need Python packages, Finder, or a GUI session. The template contains no
machine-specific paths or aliases; it applies to any mounted release volume.
https://ds-store.readthedocs.io/en/latest/
"""

from pathlib import Path

from ds_store import DSStore


with DSStore.open(str(Path(__file__).with_name("Finder.DS_Store")), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["vstl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 160}, {640, 400}}",
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 0,
        "arrangeBy": "none",
        "iconSize": 96.0,
        "textSize": 14.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": False,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["Twine.app"]["Iloc"] = (180, 110)
    store["Applications"]["Iloc"] = (460, 110)
    store["README.txt"]["Iloc"] = (180, 290)
    store["LICENSE"]["Iloc"] = (460, 290)
