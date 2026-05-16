import { access, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright";

export type SyntheticStateId =
  | "overview"
  | "deployments"
  | "filters-open"
  | "failed-detail"
  | "layout-drift-overview";

export interface SyntheticState {
  id: SyntheticStateId;
  title: string;
  fileName: string;
}

export const syntheticStates: SyntheticState[] = [
  { id: "overview", title: "Overview", fileName: "acme-overview.png" },
  { id: "deployments", title: "Deployments", fileName: "acme-deployments.png" },
  { id: "filters-open", title: "Filters Open", fileName: "acme-filters-open.png" },
  { id: "failed-detail", title: "Failed Detail", fileName: "acme-failed-detail.png" },
  { id: "layout-drift-overview", title: "Layout Drift Overview", fileName: "acme-layout-drift-overview.png" }
];

export function stateForScreenshot(filePath: string): SyntheticStateId | undefined {
  const name = path.basename(filePath);
  return syntheticStates.find((state) => state.fileName === name)?.id;
}

export function screenshotPathForState(rootDir: string, stateId: SyntheticStateId): string {
  const state = syntheticStates.find((candidate) => candidate.id === stateId);
  if (!state) {
    throw new Error(`Unknown synthetic state: ${stateId}`);
  }
  return path.join(rootDir, "fixtures", "screenshots", state.fileName);
}

export async function generateSyntheticScreens(rootDir = projectRoot(), options: { force?: boolean } = {}): Promise<string[]> {
  const outDir = path.join(rootDir, "fixtures", "screenshots");
  const dashboardDir = path.join(rootDir, "fixtures", "dashboards");
  await mkdir(outDir, { recursive: true });
  await mkdir(dashboardDir, { recursive: true });

  const expectedPaths = syntheticStates.map((state) => path.join(outDir, state.fileName));
  if (!options.force && await allFilesExist(expectedPaths)) {
    return expectedPaths;
  }

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 1 });
  const written: string[] = [];

  for (const state of syntheticStates) {
    const html = dashboardHtml(state.id);
    const htmlPath = path.join(dashboardDir, `${state.id}.html`);
    const imagePath = path.join(outDir, state.fileName);
    await writeFile(htmlPath, html, "utf8");
    await page.setContent(html, { waitUntil: "networkidle" });
    await page.screenshot({ path: imagePath, fullPage: true });
    written.push(imagePath);
  }

  await browser.close();
  return written;
}

export function dashboardHtml(stateId: SyntheticStateId): string {
  const isDeployments = stateId === "deployments" || stateId === "filters-open" || stateId === "failed-detail";
  const isFilters = stateId === "filters-open";
  const isDetail = stateId === "failed-detail";
  const isDrift = stateId === "layout-drift-overview";
  const nav = isDrift ? topNav() : sideNav(isDeployments ? "Deployments" : "Overview");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Acme Deploy Dashboard</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: #f6f7fb;
      color: #172033;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0;
    }
    .shell { display: flex; min-height: 960px; }
    .sidebar {
      width: 248px;
      background: #111827;
      color: #eef2ff;
      padding: 28px 22px;
    }
    .brand { font-size: 22px; font-weight: 750; margin-bottom: 32px; }
    .nav-item {
      display: flex;
      align-items: center;
      gap: 10px;
      height: 42px;
      padding: 0 12px;
      border-radius: 8px;
      color: #cbd5e1;
      margin-bottom: 8px;
      font-weight: 650;
    }
    .nav-item.active { background: #2563eb; color: white; }
    .main { flex: 1; padding: 28px 34px; position: relative; }
    .topbar {
      height: 54px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 26px;
    }
    .search {
      width: 380px;
      height: 42px;
      border: 1px solid #d7dce8;
      border-radius: 8px;
      background: white;
      padding: 10px 14px;
      color: #64748b;
      font-size: 14px;
    }
    .button {
      background: #0f766e;
      color: white;
      border-radius: 8px;
      padding: 11px 16px;
      font-weight: 750;
      display: inline-flex;
      align-items: center;
      gap: 8px;
    }
    .secondary {
      background: white;
      color: #334155;
      border: 1px solid #d7dce8;
    }
    .page-title { font-size: 30px; font-weight: 800; margin: 0 0 6px; }
    .muted { color: #64748b; }
    .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; margin: 24px 0; }
    .card {
      background: white;
      border: 1px solid #e1e6f0;
      border-radius: 8px;
      padding: 20px;
      box-shadow: 0 12px 30px rgba(15, 23, 42, 0.06);
    }
    .metric { font-size: 34px; font-weight: 800; margin-top: 8px; }
    .bad { color: #dc2626; }
    .good { color: #059669; }
    .warn { color: #d97706; }
    table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; }
    th, td { text-align: left; padding: 16px; border-bottom: 1px solid #edf1f7; font-size: 14px; }
    th { background: #f9fafb; color: #64748b; font-size: 12px; text-transform: uppercase; }
    .status { border-radius: 999px; padding: 5px 10px; font-weight: 800; font-size: 12px; display: inline-block; }
    .status.failed { background: #fee2e2; color: #b91c1c; }
    .status.ready { background: #dcfce7; color: #047857; }
    .status.building { background: #fef3c7; color: #b45309; }
    .toolbar { display: flex; gap: 10px; margin: 22px 0 14px; }
    .popover {
      position: absolute;
      top: 184px;
      left: 344px;
      width: 286px;
      background: white;
      border: 1px solid #d7dce8;
      border-radius: 8px;
      box-shadow: 0 18px 50px rgba(15, 23, 42, 0.18);
      padding: 16px;
      z-index: 5;
    }
    .option { padding: 10px 8px; border-radius: 6px; font-weight: 700; }
    .option.selected { background: #fee2e2; color: #b91c1c; }
    .detail {
      position: absolute;
      top: 134px;
      right: 34px;
      width: 390px;
      background: white;
      border: 1px solid #e1e6f0;
      border-radius: 8px;
      padding: 22px;
      box-shadow: 0 18px 50px rgba(15, 23, 42, 0.14);
    }
    .log {
      margin-top: 16px;
      background: #111827;
      color: #f8fafc;
      border-radius: 8px;
      padding: 14px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      line-height: 1.45;
    }
    .top-nav-layout { display: block; }
    .topnav {
      height: 74px;
      background: #111827;
      color: #f8fafc;
      display: flex;
      align-items: center;
      padding: 0 34px;
      gap: 24px;
    }
    .topnav .brand { margin: 0 28px 0 0; }
    .tab { padding: 10px 12px; border-radius: 8px; color: #cbd5e1; font-weight: 750; }
    .tab.active { background: #2563eb; color: white; }
  </style>
</head>
<body>
  ${isDrift ? `<div class="top-nav-layout">${nav}<main class="main">` : `<div class="shell">${nav}<main class="main">`}
    <div class="topbar">
      <div class="search">Search projects, deployments, commits</div>
      <div class="button">New project</div>
    </div>
    ${isDeployments ? deploymentsMarkup(isFilters, isDetail) : overviewMarkup(isDrift)}
  </main></div>
</body>
</html>`;
}

function sideNav(active: string): string {
  const items = ["Overview", "Deployments", "Projects", "Alerts", "Settings"];
  return `<aside class="sidebar">
    <div class="brand">Acme Deploy</div>
    ${items.map((item) => `<div class="nav-item ${item === active ? "active" : ""}">${item}</div>`).join("")}
  </aside>`;
}

function topNav(): string {
  const items = ["Overview", "Deployments", "Projects", "Alerts", "Settings"];
  return `<nav class="topnav">
    <div class="brand">Acme Deploy</div>
    ${items.map((item) => `<div class="tab ${item === "Overview" ? "active" : ""}">${item}</div>`).join("")}
  </nav>`;
}

function overviewMarkup(isDrift: boolean): string {
  return `<h1 class="page-title">Deployment overview</h1>
  <div class="muted">${isDrift ? "Navigation recently moved to top tabs." : "All environments across the last 24 hours."}</div>
  <section class="grid">
    <div class="card"><div class="muted">Healthy projects</div><div class="metric good">12</div></div>
    <div class="card"><div class="muted">Building now</div><div class="metric warn">3</div></div>
    <div class="card"><div class="muted">Failed deployments</div><div class="metric bad">1</div></div>
  </section>
  <section class="card">
    <h2>Recent activity</h2>
    <p><strong>Checkout API</strong> production deploy failed 18 minutes ago.</p>
    <p><strong>Web Frontend</strong> preview deploy is ready.</p>
    <p><strong>Worker Jobs</strong> is building from commit worker-77a9.</p>
  </section>`;
}

function deploymentsMarkup(filtersOpen: boolean, detailOpen: boolean): string {
  return `<h1 class="page-title">Deployments</h1>
  <div class="muted">Review deployment status across environments.</div>
  <div class="toolbar">
    <div class="button secondary">Status</div>
    <div class="button secondary">Environment</div>
    <div class="button secondary">Date range</div>
  </div>
  ${filtersOpen ? filterPopover() : ""}
  <table>
    <thead><tr><th>Deployment</th><th>Project</th><th>Environment</th><th>Status</th><th>Commit</th><th>Age</th></tr></thead>
    <tbody>
      <tr><td>api-8f31</td><td>Checkout API</td><td>Production</td><td><span class="status failed">Failed</span></td><td>8f31c2</td><td>18m</td></tr>
      <tr><td>web-2cc0</td><td>Web Frontend</td><td>Preview</td><td><span class="status ready">Ready</span></td><td>2cc0aa</td><td>24m</td></tr>
      <tr><td>worker-77a9</td><td>Worker Jobs</td><td>Staging</td><td><span class="status building">Building</span></td><td>77a901</td><td>3m</td></tr>
    </tbody>
  </table>
  ${detailOpen ? detailPanel() : ""}`;
}

function filterPopover(): string {
  return `<div class="popover">
    <strong>Status filter</strong>
    <div class="option selected">Failed</div>
    <div class="option">Ready</div>
    <div class="option">Building</div>
    <div class="option">Canceled</div>
    <div class="button" style="margin-top: 10px;">Apply filters</div>
  </div>`;
}

function detailPanel(): string {
  return `<aside class="detail">
    <h2>api-8f31</h2>
    <div><span class="status failed">Build failed</span></div>
    <p><strong>Project:</strong> Checkout API</p>
    <p><strong>Environment:</strong> Production</p>
    <p><strong>Error:</strong> Missing DATABASE_URL</p>
    <div class="toolbar">
      <div class="button secondary">View logs</div>
      <div class="button secondary">Copy error</div>
      <div class="button">Redeploy</div>
    </div>
    <div class="log">Error: Missing DATABASE_URL<br/>at loadConfig<br/>Build exited with code 1</div>
  </aside>`;
}

export function projectRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
}

async function allFilesExist(filePaths: string[]): Promise<boolean> {
  try {
    await Promise.all(filePaths.map((filePath) => access(filePath)));
    return true;
  } catch {
    return false;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  generateSyntheticScreens(projectRoot(), { force: true })
    .then((paths) => {
      for (const filePath of paths) {
        console.log(filePath);
      }
    })
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
}
