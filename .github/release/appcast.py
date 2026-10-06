#!/usr/bin/env python3
"""Publish Sparkle-generated entries from complete, published GitHub releases."""
import argparse
import base64
import copy
import datetime
import email.utils
import html
import json
from pathlib import Path
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
REPOSITORY = "aravind-n/twine"


def sparkle(name):
    return "{" + SPARKLE + "}" + name


def release_channel(release):
    tag = release["tag_name"]
    if release.get("draft"):
        return None
    if not release.get("prerelease") and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        return "stable"
    if release.get("prerelease") and re.fullmatch(r"nightly-[0-9]{8}-[0-9a-f]{12}", tag):
        return "nightly"
    return None


def validated_item(xml, release):
    items = ET.fromstring(xml).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("release appcast must contain exactly one item")
    item = copy.deepcopy(items[0])
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("missing update archive")
    version = item.findtext(sparkle("version")) or enclosure.get(sparkle("version"), "")
    if not re.fullmatch(r"[1-9][0-9]*", version):
        raise ValueError("invalid update build number")
    signature = base64.b64decode(enclosure.get(sparkle("edSignature"), ""), validate=True)
    if len(signature) != 64 or not re.fullmatch(r"[1-9][0-9]*", enclosure.get("length", "")):
        raise ValueError("missing update signature or archive length")
    tag = release["tag_name"]
    version_name = tag.removeprefix("v")
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/Twine-{version_name}-macos-universal.dmg"
    if enclosure.get("url") != expected_url:
        raise ValueError("archive URL does not belong to this release")
    archives = [asset for asset in release["assets"] if asset.get("browser_download_url") == expected_url]
    if len(archives) != 1 or archives[0]["size"] != int(enclosure.get("length")):
        raise ValueError("archive missing or size differs from signed entry")
    channel = release_channel(release)
    if item.findtext(sparkle("channel")) != ("nightly" if channel == "nightly" else None):
        raise ValueError("update channel differs from release type")
    return int(version), item


def combine(releases, load):
    entries = {"stable": [], "nightly": []}
    for release in releases:
        channel = release_channel(release)
        if channel is None:
            continue
        manifests = [asset for asset in release["assets"] if asset["name"] == "appcast.xml"]
        if not manifests:  # Releases predating Sparkle remain downloadable directly.
            continue
        if len(manifests) != 1:
            raise ValueError("duplicate release appcast")
        version, item = validated_item(load(manifests[0]), release)
        title = item.find("title")
        if title is not None:
            title.text = "Twine " + release["tag_name"].removeprefix("v")
        date = item.find("pubDate")
        if date is None:
            date = ET.SubElement(item, "pubDate")
        date.text = email.utils.format_datetime(
            datetime.datetime.fromisoformat(release["published_at"].replace("Z", "+00:00")))
        description = item.find("description")
        if description is None:
            description = ET.SubElement(item, "description")
        description.text = "<pre>" + html.escape(release.get("body") or "") + "</pre>"
        entries[channel].append((version, item))
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Twine updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{REPOSITORY}/releases"
    ET.SubElement(channel, "description").text = "Signed macOS updates for Twine"
    selected = sorted(entries["stable"], reverse=True, key=lambda entry: entry[0])[:10]
    selected += sorted(entries["nightly"], reverse=True, key=lambda entry: entry[0])[:10]
    for _, item in sorted(selected, reverse=True, key=lambda entry: entry[0]):
        channel.append(item)
    return ET.ElementTree(root)


def finalize(path, version):
    tree = ET.parse(path)
    item = tree.getroot().find("./channel/item")
    if item is None:
        raise ValueError("Sparkle did not generate an update entry")
    enclosure = item.find("enclosure")
    if enclosure is None or len(base64.b64decode(enclosure.get(sparkle("edSignature"), ""), validate=True)) != 64:
        raise ValueError("Sparkle could not sign the update; check the private/public key pair")
    item.find("title").text = "Twine " + version
    short_version = item.find(sparkle("shortVersionString"))
    if short_version is None:
        short_version = ET.SubElement(item, sparkle("shortVersionString"))
    short_version.text = version
    tree.write(path, encoding="utf-8", xml_declaration=True)


def fetch(asset):
    url = asset["browser_download_url"]
    if not url.startswith(f"https://github.com/{REPOSITORY}/releases/download/"):
        raise ValueError("appcast URL does not belong to Twine")
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read(1_048_577)
    if len(content) > 1_048_576:
        raise ValueError("release appcast exceeds size limit")
    return content


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    publish = commands.add_parser("publish")
    publish.add_argument("output", type=Path)
    patch = commands.add_parser("finalize")
    patch.add_argument("path", type=Path)
    patch.add_argument("version")
    args = parser.parse_args()
    if args.command == "finalize":
        finalize(args.path, args.version)
        return
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases?per_page=100"]))
    tree = combine([release for page in pages for release in page], fetch)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(tree)
    tree.write(args.output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
