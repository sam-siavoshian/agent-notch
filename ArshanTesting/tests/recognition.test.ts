import { describe, expect, it } from "vitest";
import { updateMemoryFromObservations } from "../src/memoryStore";
import { fixtureObservationForState } from "../src/observationPrompt";
import { recognizeState } from "../src/recognitionPrompt";

describe("state recognition", () => {
  it("matches a familiar surface and recommends a learned action", () => {
    const observations = [
      fixtureObservationForState("overview"),
      fixtureObservationForState("deployments"),
      fixtureObservationForState("filters-open"),
      fixtureObservationForState("failed-detail")
    ];
    const memory = updateMemoryFromObservations(observations, [
      { from: "overview", action: "click Deployments in the left navigation", to: "deployments", success: true, note: "Opens deployments table." }
    ]);

    const recognition = recognizeState(
      fixtureObservationForState("overview"),
      memory,
      "Find the failed deployment in the deployment dashboard."
    );

    expect(recognition.memoryHit).toBe(true);
    expect(recognition.memoryHelped).toBe(true);
    expect(recognition.recommendedFirstAction).toBe("click Deployments in the left navigation");
  });

  it("detects layout drift and avoids blindly trusting old landmarks", () => {
    const memory = updateMemoryFromObservations(
      [fixtureObservationForState("overview"), fixtureObservationForState("deployments")],
      [{ from: "overview", action: "click Deployments in the left navigation", to: "deployments", success: true, note: "Opens deployments table." }]
    );

    const recognition = recognizeState(
      fixtureObservationForState("layout-drift-overview"),
      memory,
      "Find the failed deployment in the deployment dashboard."
    );

    expect(recognition.layoutDriftDetected).toBe(true);
    expect(recognition.confidence).toBe("medium");
    expect(recognition.recommendedFirstAction).toBe("click Deployments in the top navigation");
  });
});
