import { z } from "zod";

export const RegionSchema = z.object({
  label: z.string(),
  role: z.string(),
  region: z.string(),
  confidence: z.number().min(0).max(1)
});

export const ObservationSchema = z.object({
  id: z.string(),
  timestamp: z.string(),
  source: z.enum(["gemini", "fixture", "cache"]),
  app: z.string(),
  windowTitle: z.string(),
  surfaceId: z.string(),
  surfaceLabel: z.string(),
  summary: z.string(),
  visibleControls: z.array(RegionSchema),
  visibleEntities: z.array(z.string()),
  landmarks: z.array(z.string()),
  likelyAffordances: z.array(z.string()),
  uncertainty: z.array(z.string()),
  confidence: z.number().min(0).max(1),
  screenshotPath: z.string().optional()
});

export type Observation = z.infer<typeof ObservationSchema>;
export type Region = z.infer<typeof RegionSchema>;

export function buildObservationPrompt(stateHint?: string): string {
  return [
    "You are observing a macOS screenshot for a computer-use agent.",
    "Extract only durable UI/UX facts that help the agent operate this app later.",
    "Return strict JSON with these fields:",
    "app, windowTitle, surfaceId, surfaceLabel, summary, visibleControls, visibleEntities, landmarks, likelyAffordances, uncertainty, confidence.",
    "visibleControls must contain label, role, region, confidence.",
    "Use approximate regions like left-sidebar, top-right, center-table, right-panel.",
    "Prefer uncertainty over guessing. Do not invent hidden UI.",
    stateHint ? `Known synthetic state hint: ${stateHint}` : "",
    "Return JSON only."
  ].filter(Boolean).join("\n");
}

export function parseObservationJson(rawText: string, defaults: {
  id: string;
  timestamp: string;
  source: Observation["source"];
  screenshotPath?: string;
}): Observation {
  const cleaned = rawText
    .trim()
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/\s*```$/i, "");

  const parsed = JSON.parse(cleaned) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Observation response was not a JSON object.");
  }
  return ObservationSchema.parse({
    ...parsed,
    id: defaults.id,
    timestamp: defaults.timestamp,
    source: defaults.source,
    screenshotPath: defaults.screenshotPath
  });
}

export function fixtureObservationForState(stateId: string, screenshotPath?: string): Observation {
  const base = {
    id: `fixture-${stateId}`,
    timestamp: new Date("2026-05-16T12:00:00.000Z").toISOString(),
    source: "fixture" as const,
    app: "Acme Deploy",
    windowTitle: "Acme Deploy Dashboard",
    screenshotPath
  };

  switch (stateId) {
    case "overview":
      return ObservationSchema.parse({
        ...base,
        surfaceId: "overview",
        surfaceLabel: "Dashboard overview",
        summary: "Overview surface with deployment health cards, activity feed, and left navigation.",
        visibleControls: [
          { label: "Deployments", role: "nav-item", region: "left-sidebar", confidence: 0.96 },
          { label: "Search", role: "search-field", region: "top-bar", confidence: 0.9 },
          { label: "New project", role: "button", region: "top-right", confidence: 0.86 }
        ],
        visibleEntities: ["Checkout API", "Web Frontend", "Last 24h", "1 failed deployment"],
        landmarks: ["left navigation", "health cards", "activity feed", "top search"],
        likelyAffordances: ["Open deployments from left navigation", "Search projects from top bar"],
        uncertainty: ["Blank center card area may not be directly actionable."],
        confidence: 0.91
      });
    case "deployments":
      return ObservationSchema.parse({
        ...base,
        surfaceId: "deployments",
        surfaceLabel: "Deployments table",
        summary: "Deployments table with environment, status, commit, age, and filters.",
        visibleControls: [
          { label: "Status", role: "filter", region: "table-toolbar", confidence: 0.94 },
          { label: "Environment", role: "filter", region: "table-toolbar", confidence: 0.89 },
          { label: "Failed row", role: "table-row", region: "center-table", confidence: 0.92 }
        ],
        visibleEntities: ["api-8f31", "web-2cc0", "worker-77a9", "Failed", "Production"],
        landmarks: ["deployments selected in sidebar", "status filter", "center deployment table"],
        likelyAffordances: ["Click Status filter to narrow by failed deployments", "Click a row to open deployment detail"],
        uncertainty: [],
        confidence: 0.93
      });
    case "filters-open":
      return ObservationSchema.parse({
        ...base,
        surfaceId: "filters-open",
        surfaceLabel: "Deployments filters open",
        summary: "Filter popover is open with status options including Failed.",
        visibleControls: [
          { label: "Failed", role: "filter-option", region: "center-popover", confidence: 0.97 },
          { label: "Apply filters", role: "button", region: "center-popover", confidence: 0.91 },
          { label: "Clear", role: "button", region: "center-popover", confidence: 0.82 }
        ],
        visibleEntities: ["Failed", "Ready", "Building", "Canceled"],
        landmarks: ["filter popover", "status options", "deployments table behind popover"],
        likelyAffordances: ["Select Failed to narrow the table", "Apply filters to confirm"],
        uncertainty: ["Some dashboards may apply the filter immediately after selecting Failed."],
        confidence: 0.94
      });
    case "failed-detail":
      return ObservationSchema.parse({
        ...base,
        surfaceId: "failed-detail",
        surfaceLabel: "Failed deployment detail",
        summary: "Failed deployment detail panel showing production API deployment failure and logs.",
        visibleControls: [
          { label: "View logs", role: "button", region: "right-panel", confidence: 0.9 },
          { label: "Redeploy", role: "button", region: "top-right", confidence: 0.88 },
          { label: "Copy error", role: "button", region: "right-panel", confidence: 0.81 }
        ],
        visibleEntities: ["api-8f31", "Production", "Build failed", "Missing DATABASE_URL"],
        landmarks: ["right detail panel", "red failed status", "error log excerpt"],
        likelyAffordances: ["Use View logs for details", "Copy error for sharing", "Redeploy after fixing env"],
        uncertainty: [],
        confidence: 0.95
      });
    case "layout-drift-overview":
      return ObservationSchema.parse({
        ...base,
        surfaceId: "layout-drift-overview",
        surfaceLabel: "Dashboard overview with moved navigation",
        summary: "Overview surface after a layout drift where primary navigation moved from left sidebar to top tabs.",
        visibleControls: [
          { label: "Deployments", role: "tab", region: "top-nav", confidence: 0.93 },
          { label: "Search", role: "search-field", region: "top-right", confidence: 0.84 },
          { label: "New project", role: "button", region: "top-right", confidence: 0.85 }
        ],
        visibleEntities: ["Checkout API", "Web Frontend", "Last 24h", "1 failed deployment"],
        landmarks: ["top navigation", "health cards", "activity feed", "layout drift"],
        likelyAffordances: ["Open deployments from top navigation tab"],
        uncertainty: ["Old left-sidebar navigation memory should not be reused blindly."],
        confidence: 0.82
      });
    default:
      throw new Error(`Unknown synthetic state: ${stateId}`);
  }
}
