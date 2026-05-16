import { describe, expect, it } from "vitest";
import { buildActivationBundle } from "../src/activationBundle";
import { updateMemoryFromObservations } from "../src/memoryStore";
import { fixtureObservationForState } from "../src/observationPrompt";

const userGoal = "Find the failed deployment in the deployment dashboard.";

describe("activation bundle", () => {
  it("packages current visual context with the learned UI memory needed for first action", () => {
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

    const bundle = buildActivationBundle({
      userGoal,
      observation: fixtureObservationForState("overview"),
      memory,
      recentActivity: ["User reviewed deployment health and noticed one failed deployment."]
    });

    expect(bundle.liveContext.surfaceKey).toBe("overview");
    expect(bundle.currentSurfaceMemory[0]?.text).toContain("[overview]");
    expect(bundle.relevantTransitions[0]?.action).toBe("click Deployments in the left navigation");
    expect(bundle.relevantTaskRecipes[0]?.text).toContain("Find failed deployment");
    expect(bundle.negativeMemory[0]?.text).toContain("blank center");
    expect(bundle.firstActionHint).toBe("click Deployments in the left navigation");
  });
});
