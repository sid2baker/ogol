"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");
const {chromium} = require("playwright");
const {expect} = require("@playwright/test");

function headlessEnabled() {
  return !["0", "false", "no"].includes(
    String(process.env.PLAYWRIGHT_HEADLESS || "true").toLowerCase()
  );
}

function slowMoMs() {
  const value = Number.parseInt(process.env.PLAYWRIGHT_SLOW_MO || "0", 10);
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function keepOpenEnabled() {
  return ["1", "true", "yes"].includes(
    String(process.env.PLAYWRIGHT_KEEP_OPEN || "false").toLowerCase()
  );
}

function launchOptions() {
  return {
    headless: headlessEnabled(),
    slowMo: slowMoMs()
  };
}

async function readPayload(payloadPath) {
  const raw = await fs.readFile(payloadPath, "utf8");
  return JSON.parse(raw);
}

async function writeFailureArtifacts(page, artifactDir) {
  if (!artifactDir) return {};

  await fs.mkdir(artifactDir, {recursive: true});

  const screenshotPath = path.join(artifactDir, "failure.png");
  const htmlPath = path.join(artifactDir, "page.html");

  await page.screenshot({path: screenshotPath, fullPage: true}).catch(() => {});
  const html = await page.content().catch(() => null);

  if (html) {
    await fs.writeFile(htmlPath, html);
  }

  return {screenshotPath, htmlPath};
}

async function checkAvailability() {
  const browser = await chromium.launch(launchOptions());
  await browser.close();
}

async function runScript(payloadPath) {
  const payload = await readPayload(payloadPath);
  const browser = await chromium.launch(launchOptions());
  const browserContext = await browser.newContext({
    baseURL: payload.baseUrl,
    viewport: {width: 1440, height: 960}
  });
  const page = await browserContext.newPage();

  try {
    if (process.env.PLAYWRIGHT_PAUSE === "true") {
      await page.pause();
    }

    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    const execute = new AsyncFunction("page", "context", "expect", payload.script);
    await execute(page, payload.context || {}, expect);

    if (keepOpenEnabled()) {
      process.stdout.write(
        "Playwright script completed. Browser left open for inspection. Press Ctrl+C to close.\n"
      );
      await waitForShutdownSignal(browser);
      return;
    }

    await browser.close();
  } catch (error) {
    const artifacts = await writeFailureArtifacts(page, payload.artifactDir);

    process.stderr.write(
      [
        error && error.stack ? error.stack : String(error),
        artifacts.screenshotPath ? `screenshot: ${artifacts.screenshotPath}` : null,
        artifacts.htmlPath ? `page_html: ${artifacts.htmlPath}` : null
      ]
      .filter(Boolean)
      .join("\n") + "\n"
    );

    await browser.close().catch(() => {});
    process.exit(1);
  }
}

async function waitForShutdownSignal(browser) {
  await new Promise((resolve) => {
    const shutdown = async () => {
      process.removeListener("SIGINT", shutdown);
      process.removeListener("SIGTERM", shutdown);
      await browser.close().catch(() => {});
      resolve();
    };

    process.once("SIGINT", shutdown);
    process.once("SIGTERM", shutdown);
  });
}

async function main() {
  const arg = process.argv[2];

  if (arg === "--check") {
    await checkAvailability();
    return;
  }

  if (!arg) {
    throw new Error("expected payload path");
  }

  await runScript(arg);
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack ? error.stack : String(error)}\n`);
  process.exit(1);
});
