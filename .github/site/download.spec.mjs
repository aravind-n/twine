import { test as base, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { dmgName, repositoryRoot, serveSite, sha256 } from "./server.mjs";

const apiURL = "https://api.github.com/repos/aravind-n/twine/releases/latest";
const releasesURL = "https://github.com/aravind-n/twine/releases/latest";
const buttonSelector = "[data-macos-download]";
const locations = ["hero", "start"];
const test = base.extend({
  site: [async ({}, use) => {
    const site = await serveSite();
    await use(site);
    await site.close();
  }, { scope: "worker" }],
});

function asset(site, name = dmgName, state = "uploaded") {
  return { name, state, browser_download_url: `${site.url}/downloads/${name}` };
}

async function release(page, assets) {
  await page.route(apiURL, (route) => route.fulfill({ json: { assets } }));
}

async function expectReady(page) {
  for (const location of locations) {
    const button = page.locator(`[data-macos-download="${location}-download-status"]`);
    await expect(button).not.toHaveAttribute("aria-busy");
    await expect(button).not.toHaveAttribute("aria-disabled");
  }
}

async function downloadFrom(page, site, location, testInfo, saveForInstall = false) {
  const downloadPromise = page.waitForEvent("download");
  await page.locator(`[data-macos-download="${location}-download-status"]`).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe(dmgName);
  expect(download.url()).toBe(`${site.url}/downloads/${dmgName}`);
  const outputDirectory = saveForInstall && process.env.TWINE_TEST_DOWNLOAD_DIR && resolve(repositoryRoot, process.env.TWINE_TEST_DOWNLOAD_DIR, location);
  if (outputDirectory) await mkdir(outputDirectory, { recursive: true });
  const output = outputDirectory ? resolve(outputDirectory, dmgName) : testInfo.outputPath(dmgName);
  await download.saveAs(output);
  expect(await download.failure()).toBeNull();
  expect(await sha256(output)).toBe(site.expectedHash);
  return output;
}

test.beforeEach(async ({ context }) => {
  // Every external request is explicitly stubbed so this suite needs no GitHub access.
  await context.route("https://**/*", (route) => route.abort());
});

for (const location of locations) {
  test(`${location} CTA downloads the universal DMG instead of ZIP or library assets`, async ({ page, site }, testInfo) => {
    await release(page, [
      asset(site, "Twine-1.2.3-macos-universal.zip"),
      asset(site, "twine-core-1.2.3-macos-universal.tar.gz"),
      asset(site, "Twine-1.2.3-macos-arm64.dmg"),
      asset(site, "Twine-incomplete-macos-universal.dmg", "new"),
      asset(site),
    ]);
    await page.goto(site.url);
    await downloadFrom(page, site, location, testInfo, true);
    await expect(page.locator(`#${location}-download-status`)).toContainText("drag Twine to Applications");
    await expect(page.locator(`#${location}-download-status a`)).toBeHidden();
    for (const button of await page.locator(buttonSelector).all()) {
      await expect(button).toHaveAttribute("href", `${site.url}/downloads/${dmgName}`);
    }
    await expectReady(page);
    expect(page.url()).toBe(`${site.url}/`);
  });
}

test("a ZIP-only release shows an explicit DMG fallback and allows retry", async ({ page, site }, testInfo) => {
  const downloads = [];
  page.on("download", (download) => downloads.push(download));
  await release(page, [asset(site, "Twine-0.1.0-macos-universal.zip")]);
  await page.goto(site.url);
  await page.locator(buttonSelector).first().click();
  const feedback = page.locator("#hero-download-status");
  await expect(feedback).toContainText("A DMG installer isn’t available");
  await expect(feedback.locator("a")).toBeVisible();
  await expect(feedback.locator("a")).toHaveAttribute("href", releasesURL);
  expect(downloads).toHaveLength(0);
  await expectReady(page);
  await release(page, [asset(site)]);
  await downloadFrom(page, site, "hero", testInfo);
  await expect(feedback.locator("a")).toBeHidden();
});

for (const assets of [undefined, [], [{ name: dmgName, state: "uploaded" }]]) {
  test(`missing DMG metadata is handled: ${JSON.stringify(assets)}`, async ({ page, site }) => {
    await release(page, assets);
    await page.goto(site.url);
    await page.locator(buttonSelector).first().click();
    await expect(page.locator("#hero-download-status")).toContainText("A DMG installer isn’t available");
    await expect(page.locator("#hero-download-status a")).toBeVisible();
    await expectReady(page);
  });
}

for (const failure of ["HTTP error", "network error", "invalid JSON"]) {
  test(`${failure} shows a release link and allows retry`, async ({ page, site }, testInfo) => {
    await page.route(apiURL, (route) => {
      if (failure === "network error") return route.abort();
      return route.fulfill({ status: failure === "HTTP error" ? 403 : 200, body: "unavailable" });
    });
    await page.goto(site.url);
    await page.locator(buttonSelector).first().click();
    await expect(page.locator("#hero-download-status")).toContainText("Please try again");
    await expect(page.locator("#hero-download-status a")).toBeVisible();
    await expectReady(page);
    await release(page, [asset(site)]);
    await downloadFrom(page, site, "hero", testInfo);
  });
}

test("a slow lookup times out, restores both CTAs, and allows retry", async ({ page, site }, testInfo) => {
  await page.clock.install();
  await page.route(apiURL, () => {});
  await page.goto(site.url);
  await page.locator(buttonSelector).first().click();
  await expect(page.locator("#hero-download-status")).toContainText("Finding the latest macOS DMG");
  for (const button of await page.locator(buttonSelector).all()) {
    await expect(button).toHaveAttribute("aria-busy", "true");
    await expect(button).toHaveAttribute("aria-disabled", "true");
  }
  await page.clock.fastForward(10001);
  await expect(page.locator("#hero-download-status")).toContainText("Please try again");
  await expectReady(page);
  await release(page, [asset(site)]);
  await downloadFrom(page, site, "start", testInfo);
});

test("repeated clicks while resolving start only one lookup and download", async ({ page, site }, testInfo) => {
  let lookups = 0;
  let complete;
  const pending = new Promise((resolve) => { complete = resolve; });
  await page.route(apiURL, async (route) => {
    lookups += 1;
    await pending;
    await route.fulfill({ json: { assets: [asset(site)] } });
  });
  await page.goto(site.url);
  await page.locator(buttonSelector).first().click();
  // Disabled links are intentionally exercised through DOM clicks, which still dispatch their handlers.
  await page.locator(buttonSelector).evaluateAll((buttons) => {
    for (const button of buttons) button.click();
  });
  const downloadPromise = page.waitForEvent("download");
  complete();
  const download = await downloadPromise;
  await download.saveAs(testInfo.outputPath(dmgName));
  expect(lookups).toBe(1);
  await expectReady(page);
});

test("modified clicks preserve the browser's normal link handling", async ({ page, site }) => {
  let lookups = 0;
  await page.route(apiURL, (route) => { lookups += 1; return route.abort(); });
  await page.goto(site.url);
  const prevented = await page.locator(buttonSelector).first().evaluate((button) => {
    const prevented = [];
    button.addEventListener("click", (event) => {
      // Observe the production handler before suppressing platform-specific new tabs/windows.
      prevented.push(event.defaultPrevented);
      event.preventDefault();
    });
    for (const modifier of [{ metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }]) {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ...modifier }));
    }
    return prevented;
  });
  expect(prevented).toEqual([false, false, false, false, false]);
  expect(lookups).toBe(0);
  await expect(page.locator(buttonSelector).first()).toHaveAttribute("href", releasesURL);
  await expect(page.locator("#hero-download-status")).toBeHidden();
});

test.describe("without JavaScript", () => {
  test.use({ javaScriptEnabled: false });
  for (const location of locations) {
    test(`${location} CTA still opens GitHub releases`, async ({ page, context, site }) => {
      await context.route(releasesURL, (route) => route.fulfill({ contentType: "text/html", body: "<h1>GitHub releases</h1>" }));
      await page.goto(site.url);
      await page.locator(`[data-macos-download="${location}-download-status"]`).click();
      await expect(page).toHaveURL(releasesURL);
      await expect(page.locator("h1")).toHaveText("GitHub releases");
    });
  }
});
