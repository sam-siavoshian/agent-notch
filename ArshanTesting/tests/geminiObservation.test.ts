import { describe, expect, it } from "vitest";
import { observeScreenshotWithGemini } from "../src/geminiClient";
import { assessObservationQuality } from "../src/observationQuality";
import { ObservationSchema } from "../src/observationPrompt";
import { projectRoot, screenshotPathForState, syntheticStates } from "../src/syntheticScreens";

describe("Gemini observation pipeline", () => {
  it("returns valid fixture observations with required UI facts for every synthetic screenshot", async () => {
    const rootDir = projectRoot();

    for (const state of syntheticStates) {
      const screenshotPath = screenshotPathForState(rootDir, state.id);
      const observation = await observeScreenshotWithGemini(screenshotPath, {
        rootDir,
        live: false,
        useCache: false
      });

      expect(() => ObservationSchema.parse(observation)).not.toThrow();
      expect(observation.app).toBe("Acme Deploy");
      expect(assessObservationQuality(observation, state.id)).toMatchObject({
        passed: true,
        missingFacts: []
      });
    }
  });

  const liveIt = process.env.ARSHAN_LIVE_GEMINI === "1" ? it : it.skip;

  liveIt("runs a blinded uncached live Gemini observation when explicitly enabled", async () => {
    expect(process.env.GEMINI_API_KEY).toBeTruthy();
    const rootDir = projectRoot();
    const screenshotPath = screenshotPathForState(rootDir, "overview");
    const observation = await observeScreenshotWithGemini(screenshotPath, {
      rootDir,
      live: true,
      useCache: false,
      allowFixtureFallback: false
    });

    expect(() => ObservationSchema.parse(observation)).not.toThrow();
    const quality = assessObservationQuality(observation, "overview");
    expect(quality.score).toBeGreaterThanOrEqual(0.75);
    expect(quality.missingFacts).not.toContain("Deployments");
  }, 30_000);
});
