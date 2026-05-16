import { describe, expect, it } from "vitest";
import { observeScreenshotWithGemini } from "../src/geminiClient";
import { ObservationSchema } from "../src/observationPrompt";
import { projectRoot, screenshotPathForState } from "../src/syntheticScreens";

describe("Gemini observation pipeline", () => {
  it("returns a valid observation for a dashboard screenshot", async () => {
    const rootDir = projectRoot();

    const screenshotPath = screenshotPathForState(rootDir, "overview");
    const observation = await observeScreenshotWithGemini(screenshotPath, {
      rootDir,
      stateHint: "overview",
      live: process.env.ARSHAN_LIVE_GEMINI === "1"
    });

    expect(() => ObservationSchema.parse(observation)).not.toThrow();
    expect(observation.app).toBe("Acme Deploy");
    expect(observation.visibleControls.length).toBeGreaterThan(0);
    expect(observation.likelyAffordances.join(" ").toLowerCase()).toContain("deployments");
  });
});
