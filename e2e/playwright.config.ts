import {defineConfig, devices} from "@playwright/test"
import path from "node:path"

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  workers: 1,
  timeout: 600_000,
  expect: {timeout: 30_000},
  retries: 0,
  outputDir: path.resolve("../output/playwright/test-results"),
  reporter: [["line"]],
  use: {
    baseURL: process.env.DRAMATIZER_E2E_URL || "http://127.0.0.1:4100",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure"
  },
  projects: [
    {
      name: "chromium",
      use: {...devices["Desktop Chrome"]}
    }
  ]
})
