import { MediaResolution } from "@google/genai";
import { observeScreenshotWithGemini } from "./geminiClient";
import { projectRoot, screenshotPathForState, SyntheticStateId } from "./syntheticScreens";

interface BenchmarkResult {
  model: string;
  mediaResolution: string;
  state: SyntheticStateId;
  elapsedMs: number;
  ok: boolean;
  controls: number;
  entities: number;
  error?: string;
}

const defaultModels = [
  "gemini-3.1-flash-lite",
  "gemini-2.5-flash-lite",
  "gemini-2.5-flash",
  "gemini-3-flash-preview"
];

const resolutionMap: Record<string, MediaResolution> = {
  low: MediaResolution.MEDIA_RESOLUTION_LOW,
  medium: MediaResolution.MEDIA_RESOLUTION_MEDIUM,
  high: MediaResolution.MEDIA_RESOLUTION_HIGH
};

async function main(): Promise<void> {
  if (!process.env.GEMINI_API_KEY) {
    throw new Error("GEMINI_API_KEY is required for live benchmarks.");
  }

  const rootDir = projectRoot();
  const state = (process.env.BENCH_STATE ?? "overview") as SyntheticStateId;
  const models = (process.env.BENCH_MODELS ?? defaultModels.join(","))
    .split(",")
    .map((model) => model.trim())
    .filter(Boolean);
  const resolutions = (process.env.BENCH_RESOLUTIONS ?? "low,medium")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);

  const results: BenchmarkResult[] = [];
  for (const model of models) {
    for (const resolution of resolutions) {
      const startedAt = performance.now();
      try {
        const observation = await observeScreenshotWithGemini(screenshotPathForState(rootDir, state), {
          rootDir,
          stateHint: state,
          live: true,
          useCache: false,
          model,
          mediaResolution: resolutionMap[resolution] ?? MediaResolution.MEDIA_RESOLUTION_LOW
        });
        results.push({
          model,
          mediaResolution: resolution,
          state,
          elapsedMs: Math.round(performance.now() - startedAt),
          ok: true,
          controls: observation.visibleControls.length,
          entities: observation.visibleEntities.length
        });
      } catch (error) {
        results.push({
          model,
          mediaResolution: resolution,
          state,
          elapsedMs: Math.round(performance.now() - startedAt),
          ok: false,
          controls: 0,
          entities: 0,
          error: error instanceof Error ? error.message : String(error)
        });
      }
    }
  }

  console.table(results.map((result) => ({
    model: result.model,
    media: result.mediaResolution,
    ms: result.elapsedMs,
    ok: result.ok,
    controls: result.controls,
    entities: result.entities,
    error: result.error?.slice(0, 80) ?? ""
  })));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
