import { MediaResolution } from "@google/genai";
import { stat } from "node:fs/promises";
import { observeScreenshotWithGemini } from "./geminiClient";
import { prepareGeminiImage, type ImageRequestConfig } from "./imagePreprocess";
import { projectRoot, screenshotPathForState, SyntheticStateId } from "./syntheticScreens";

interface BenchmarkResult {
  model: string;
  mediaResolution: string;
  imageMode: string;
  state: SyntheticStateId;
  sourceKb: number;
  requestKb: number;
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
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    console.log([
      "Gemini screenshot benchmark",
      "",
      "Required:",
      "  GEMINI_API_KEY=...",
      "",
      "Optional:",
      "  BENCH_MODELS=gemini-3.1-flash-lite,gemini-2.5-flash-lite",
      "  BENCH_RESOLUTIONS=low,medium",
      "  BENCH_IMAGE_MODES=auto,original,opt-960-70,opt-720-70",
      "  BENCH_STATE=overview",
      "",
      "Example:",
      "  BENCH_MODELS=gemini-3.1-flash-lite BENCH_IMAGE_MODES=auto,original npm run bench:gemini"
    ].join("\n"));
    return;
  }

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
  const imageModes = (process.env.BENCH_IMAGE_MODES ?? "optimized")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);

  const results: BenchmarkResult[] = [];
  const screenshotPath = screenshotPathForState(rootDir, state);
  const sourceKb = Math.round((await stat(screenshotPath)).size / 1024);
  for (const model of models) {
    for (const resolution of resolutions) {
      for (const imageMode of imageModes) {
        const imageConfig = imageConfigForMode(imageMode);
        const preparedImage = await prepareGeminiImage(screenshotPath, rootDir, imageConfig);
        const requestKb = Math.round((await stat(preparedImage.path)).size / 1024);
        const startedAt = performance.now();
        try {
          const observation = await observeScreenshotWithGemini(screenshotPath, {
            rootDir,
            live: true,
            useCache: false,
            model,
            mediaResolution: resolutionMap[resolution] ?? MediaResolution.MEDIA_RESOLUTION_LOW,
            imageConfig
          });
          results.push({
            model,
            mediaResolution: resolution,
            imageMode,
            state,
            sourceKb,
            requestKb,
            elapsedMs: Math.round(performance.now() - startedAt),
            ok: true,
            controls: observation.visibleControls.length,
            entities: observation.visibleEntities.length
          });
        } catch (error) {
          results.push({
            model,
            mediaResolution: resolution,
            imageMode,
            state,
            sourceKb,
            requestKb,
            elapsedMs: Math.round(performance.now() - startedAt),
            ok: false,
            controls: 0,
            entities: 0,
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
    }
  }

  console.table(results.map((result) => ({
    model: result.model,
    media: result.mediaResolution,
    image: result.imageMode,
    sourceKb: result.sourceKb,
    requestKb: result.requestKb,
    ms: result.elapsedMs,
    ok: result.ok,
    controls: result.controls,
    entities: result.entities,
    error: result.error?.slice(0, 80) ?? ""
  })));
}

function imageConfigForMode(mode: string): ImageRequestConfig {
  if (mode === "auto") {
    return {
      mode: "auto",
      autoThresholdKb: Number(process.env.GEMINI_IMAGE_AUTO_THRESHOLD_KB ?? 250),
      maxSize: Number(process.env.GEMINI_IMAGE_MAX_SIZE ?? 960),
      jpegQuality: Number(process.env.GEMINI_JPEG_QUALITY ?? 70)
    };
  }
  if (mode === "original") return { mode: "original" };

  const match = /^opt(?:imized)?-(\d+)(?:-(\d+))?$/.exec(mode);
  if (match) {
    return {
      mode: "optimized",
      maxSize: Number(match[1]),
      jpegQuality: Number(match[2] ?? 70)
    };
  }

  return {
    mode: "optimized",
    maxSize: Number(process.env.GEMINI_IMAGE_MAX_SIZE ?? 960),
    jpegQuality: Number(process.env.GEMINI_JPEG_QUALITY ?? 70)
  };
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
