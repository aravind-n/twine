import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "download.spec.mjs",
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  workers: 2,
  reporter: "list",
  use: {
    browserName: "chromium",
    acceptDownloads: true,
    trace: "retain-on-failure",
  },
});
