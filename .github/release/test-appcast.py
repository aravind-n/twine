#!/usr/bin/env python3
import base64
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).with_name("appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


def fixture(tag="v1.2.3", build=42, prerelease=False):
    version = tag.removeprefix("v")
    url = f"https://github.com/aravind-n/twine/releases/download/{tag}/Twine-{version}-macos-universal.dmg"
    signature = base64.b64encode(bytes(64)).decode()
    channel = "<sparkle:channel>nightly</sparkle:channel>" if prerelease else ""
    xml = f'<rss xmlns:sparkle="{appcast.SPARKLE}"><channel><item><title>Twine</title>' \
        f'<sparkle:version>{build}</sparkle:version>{channel}' \
        f'<enclosure url="{url}" length="123" sparkle:edSignature="{signature}"/>' \
        '</item></channel></rss>'
    release = {"tag_name": tag, "draft": False, "prerelease": prerelease,
               "published_at": "2026-10-06T09:00:00Z", "body": "<script>example</script>",
               "assets": [{"name": "appcast.xml", "xml": xml},
                          {"name": "update.dmg", "browser_download_url": url, "size": 123}]}
    return release


class AppcastTests(unittest.TestCase):
    def combine(self, releases):
        return appcast.combine(releases, lambda asset: asset["xml"]).getroot().findall("./channel/item")

    def test_combines_stable_and_nightly_by_numeric_build(self):
        items = self.combine([fixture(build=9), fixture("nightly-20261006-abcdef123456", 100, True)])
        self.assertEqual([item.findtext(appcast.sparkle("version")) for item in items], ["100", "9"])
        self.assertEqual(items[0].findtext(appcast.sparkle("channel")), "nightly")
        self.assertIsNone(items[1].find(appcast.sparkle("channel")))
        self.assertIn("&lt;script&gt;", items[0].findtext("description"))

    def test_drafts_legacy_and_other_prereleases_are_excluded(self):
        draft = fixture(); draft["draft"] = True
        legacy = fixture(); legacy["assets"] = []
        beta = fixture("v1.2.4-beta", prerelease=True)
        self.assertEqual(self.combine([draft, legacy, beta]), [])

    def test_rejects_missing_signature_mismatched_archive_and_wrong_channel(self):
        for mutation in [
            lambda release: release["assets"][1].update(size=124),
            lambda release: release.update(prerelease=False),
            lambda release: release["assets"][0].update(xml=release["assets"][0]["xml"].replace("edSignature", "unsigned")),
            lambda release: release["assets"][0].update(xml=release["assets"][0]["xml"].replace("https://github.com/", "https://other.example/")),
            lambda release: release["assets"][0].update(xml=release["assets"][0]["xml"].replace("<sparkle:version>42", "<sparkle:version>0")),
        ]:
            release = fixture("nightly-20261006-abcdef123456", prerelease=True)
            mutation(release)
            with self.assertRaises(ValueError):
                appcast.validated_item(release["assets"][0]["xml"], release)

    def test_limits_retained_versions_per_channel(self):
        items = self.combine([fixture(build=value) for value in range(1, 22)])
        self.assertEqual(len(items), 10)
        self.assertEqual(items[-1].findtext(appcast.sparkle("version")), "12")


if __name__ == "__main__":
    unittest.main()
