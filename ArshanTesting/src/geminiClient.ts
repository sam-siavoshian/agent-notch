import { GoogleGenAI } from "@google/genai";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { buildObservationPrompt, fixtureObservationForState, Observation, parseObservationJson } from "./observationPrompt";
import { projectRoot, stateForScreenshot } from "./syntheticScreens";

export interface GeminiObservationOptions {
  rootDir?: string;
  stateHint?: string;
  live?: boolean;
  allowFixtureFallback?: boolean;
}

export async function observeScreenshotWithGemini(
  screenshotPath: string,
  options: GeminiObservationOptions = {}
): Promise<Observation> {
  const rootDir = options.rootDir ?? projectRoot();
  const prompt = buildObservationPrompt(options.stateHint);
  const imageBytes = await readFile(screenshotPath);
  const cachePath = await cacheFileFor(rootDir, imageBytes, prompt);
  const now = new Date().toISOString();

  const cached = await readCached(cachePath, screenshotPath);
  if (cached) {
    return cached;
  }

  const shouldUseLive = options.live ?? process.env.ARSHAN_LIVE_GEMINI === "1";
  const apiKey = process.env.GEMINI_API_KEY;
  if (shouldUseLive && apiKey) {
    const model = process.env.GEMINI_MODEL ?? "gemini-3-flash-preview";
    const ai = new GoogleGenAI({ apiKey });
    const response = await ai.models.generateContent({
      model,
      contents: [
        {
          inlineData: {
            mimeType: mimeTypeFor(screenshotPath),
            data: imageBytes.toString("base64")
          }
        },
        { text: prompt }
      ],
      config: {
        responseMimeType: "application/json"
      }
    });

    const text = response.text ?? "";
    const observation = parseObservationJson(text, {
      id: cacheId(imageBytes, prompt),
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

async function cacheFileFor(rootDir: string, imageBytes: Buffer, prompt: string): Promise<string> {
  const dir = path.join(rootDir, "memory", "cache");
  await mkdir(dir, { recursive: true });
  return path.join(dir, `gemini-${cacheId(imageBytes, prompt)}.json`);
}

function cacheId(imageBytes: Buffer, prompt: string): string {
  return createHash("sha256").update(imageBytes).update(prompt).digest("hex").slice(0, 24);
}

function mimeTypeFor(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".webp") return "image/webp";
  if (ext === ".heic") return "image/heic";
  if (ext === ".heif") return "image/heif";
  return "image/png";
}
