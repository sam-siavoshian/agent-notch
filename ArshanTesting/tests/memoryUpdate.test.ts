import { describe, expect, it } from "vitest";
import { canonicalSurfaceKey, updateMemoryFromObservations, renderAppMemoryMarkdown } from "../src/memoryStore";
import { fixtureObservationForState } from "../src/observationPrompt";

describe("memory update", () => {
  it("stores durable UI facts, transitions, recipes, and negative memory", () => {
    const observations = [
      fixtureObservationForState("overview"),
      fixtureObservationForState("deployments"),
      fixtureObservationForState("filters-open"),
      fixtureObservationForState("failed-detail")
    ];
    const memory = updateMemoryFromObservations(observations, [
      { from: "overview", action: "click blank center area", to: "overview", success: false, note: "Blank center area is not actionable." },
      { from: "overview", action: "click Deployments in the left navigation", to: "deployments", success: true, note: "Opens deployments table." },
      { from: "deployments", action: "click Status filter", to: "filters-open", success: true, note: "Opens filter panel." },
      { from: "filters-open", action: "select Failed status", to: "failed-detail", success: true, note: "Narrows to failed deployment." }
    ]);

    const markdown = renderAppMemoryMarkdown(memory);
    expect(memory.surfaces.length).toBeGreaterThanOrEqual(4);
    expect(memory.transitions).toHaveLength(3);
    expect(memory.negativeMemory[0]?.text).toContain("Blank center");
    expect(markdown).toContain("Find failed deployment");
    expect(markdown).not.toContain("one-off");
  });

  it("normalizes unstable model surface IDs before learning transitions", () => {
    const overview = {
      ...fixtureObservationForState("overview"),
      surfaceId: "main-dashboard",
      surfaceLabel: "Deployment overview"
    };
    const deployments = {
      ...fixtureObservationForState("deployments"),
      surfaceId: "deployments_dashboard",
      surfaceLabel: "Acme Deploy Deployments Dashboard"
    };
    const memory = updateMemoryFromObservations([overview, deployments], [
      { from: "overview", action: "click Deployments in the left navigation", to: "deployments", success: true, note: "Opens deployments table." }
    ]);

    expect(canonicalSurfaceKey(overview)).toBe("overview");
    expect(canonicalSurfaceKey(deployments)).toBe("deployments");
    expect(memory.surfaces.map((surface) => surface.text)).toEqual(
      expect.arrayContaining([
        expect.stringContaining("[overview]"),
        expect.stringContaining("[deployments]")
      ])
    );
    expect(memory.transitions[0]?.evidenceIds).toEqual(expect.arrayContaining([overview.id, deployments.id]));
  });
});
