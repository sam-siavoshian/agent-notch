import { GoogleGenAI, MediaResolution } from "@google/genai";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { imageRequestFromEnv, prepareGeminiImage, type ImageRequestConfig } from "./imagePreprocess";
import { buildObservationPrompt, fixtureObservationForState, Observation, ObservationJsonSchema, parseObservationJson } from "./observationPrompt";
import { projectRoot, stateForScreenshot } from "./syntheticScreens";

export interface GeminiObservationOptions {
  rootDir?: string;
  stateHint?: string;
  live?: boolean;
  allowFixtureFallback?: boolean;
  useCache?: boolean;
  model?: string;
  mediaResolution?: MediaResolution;
  imageConfig?: ImageRequestConfig;
}

export async function observeScreenshotWithGemini(
  screenshotPath: string,
  options: GeminiObservationOptions = {}
): Promise<Observation> {
  const rootDir = options.rootDir ?? projectRoot();
  const prompt = buildObservationPrompt(options.stateHint);
  const imageConfig = options.imageConfig ?? imageRequestFromEnv();
  const imageRequest = await prepareGeminiImage(screenshotPath, rootDir, imageConfig);
  const imageBytes = await readFile(imageRequest.path);
  const model = options.model ?? process.env.GEMINI_MODEL ?? "gemini-3.1-flash-lite";
  const mediaResolution = options.mediaResolution ?? mediaResolutionFromEnv();
  const maxOutputTokens = Number(process.env.GEMINI_MAX_OUTPUT_TOKENS ?? 1600);
  const cachePath = await cacheFileFor(rootDir, imageBytes, {
    prompt,
    model,
    mediaResolution,
    maxOutputTokens,
    imageConfig: imageRequest.cacheConfig
  });
  const now = new Date().toISOString();

  const cached = options.useCache === false ? undefined : await readCached(cachePath, screenshotPath);
  if (cached) {
    return cached;
  }

  const shouldUseLive = options.live ?? process.env.ARSHAN_LIVE_GEMINI === "1";
  const apiKey = process.env.GEMINI_API_KEY;
  if (shouldUseLive && apiKey) {
    const ai = new GoogleGenAI({ apiKey });
    const response = await ai.models.generateContent({
      model,
      contents: [
        {
          inlineData: {
            mimeType: imageRequest.mimeType,
            data: imageBytes.toString("base64")
          }
        },
        { text: prompt }
      ],
      config: {
        responseMimeType: "application/json",
        responseJsonSchema: ObservationJsonSchema,
        mediaResolution,
        maxOutputTokens,
        temperature: 0
      }
    });

    const text = response.text ?? "";
    const observation = parseObservationJson(text, {
      id: cacheId(imageBytes, { prompt, model, mediaResolution, maxOutputTokens, imageConfig: imageRequest.cacheConfig }),
      timestamp: now,
      source: "gemini",
      screenshotPath
    });
    await writeFile(cachePath, JSON.stringify(observation, null, 2), "utf8");
    return observation;
  }

  if (options.allowFixtureFallback ?? true) {
    const state = options.stateHint ?? stateForScreenshot(screenshotPath);
    if (state) {
      return fixtureObservationForState(state, screenshotPath);
    }
  }

  throw new Error("No Gemini cache available and live Gemini is disabled or missing GEMINI_API_KEY.");
}

async function readCached(cachePath: string, screenshotPath: string): Promise<Observation | undefined> {
  try {
    const raw = await readFile(cachePath, "utf8");
    return {
      ...JSON.parse(raw),
      source: "cache",
      screenshotPath
    } as Observation;
  } catch {
    return undefined;
  }
}

async function cacheFileFor(rootDir: string, imageBytes: Buffer, config: CacheConfig): Promise<string> {
  const dir = path.join(rootDir, "memory", "cache");
  await mkdir(dir, { recursive: true });
  return path.join(dir, `gemini-${cacheId(imageBytes, config)}.json`);
}

interface CacheConfig {
  prompt: string;
  model: string;
  mediaResolution: MediaResolution;
  maxOutputTokens: number;
  imageConfig: string;
}

function cacheId(imageBytes: Buffer, config: CacheConfig): string {
  return createHash("sha256").update(imageBytes).update(JSON.stringify(config)).digest("hex").slice(0, 24);
}

export function mediaResolutionFromEnv(): MediaResolution {
  const value = (process.env.GEMINI_MEDIA_RESOLUTION ?? "low").toLowerCase();
  if (value === "medium") return MediaResolution.MEDIA_RESOLUTION_MEDIUM;
  if (value === "high") return MediaResolution.MEDIA_RESOLUTION_HIGH;
  return MediaResolution.MEDIA_RESOLUTION_LOW;
}
