import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface ImageRequestConfig {
  mode: "auto" | "original" | "optimized";
  autoThresholdKb?: number;
  maxSize?: number;
  jpegQuality?: number;
}

export interface PreparedGeminiImage {
  path: string;
  mimeType: string;
  cacheConfig: string;
}

export function imageRequestFromEnv(): ImageRequestConfig {
  const modeValue = (process.env.GEMINI_IMAGE_MODE ?? "auto").toLowerCase();
  const mode = modeValue === "original" || modeValue === "optimized" ? modeValue : "auto";
  return {
    mode,
    autoThresholdKb: Number(process.env.GEMINI_IMAGE_AUTO_THRESHOLD_KB ?? 250),
    maxSize: Number(process.env.GEMINI_IMAGE_MAX_SIZE ?? 960),
    jpegQuality: Number(process.env.GEMINI_JPEG_QUALITY ?? 70)
  };
}

export async function prepareGeminiImage(
  sourcePath: string,
  rootDir: string,
  config: ImageRequestConfig
): Promise<PreparedGeminiImage> {
  const sourceBytes = await readFile(sourcePath);
  const autoThresholdKb = config.autoThresholdKb ?? 250;
  const shouldUseOriginal = config.mode === "original" ||
    (config.mode === "auto" && sourceBytes.byteLength <= autoThresholdKb * 1024);

  if (shouldUseOriginal) {
    return {
      path: sourcePath,
      mimeType: mimeTypeFor(sourcePath),
      cacheConfig: config.mode === "auto" ? `auto:original:${autoThresholdKb}` : "original"
    };
  }

  const maxSize = config.maxSize ?? 960;
  const jpegQuality = config.jpegQuality ?? 70;
  const id = createHash("sha256")
    .update(sourceBytes)
    .update(JSON.stringify({ mode: config.mode, autoThresholdKb, maxSize, jpegQuality }))
    .digest("hex")
    .slice(0, 24);
  const outDir = path.join(rootDir, "memory", "preprocessed");
  const outPath = path.join(outDir, `${id}-${maxSize}-${jpegQuality}.jpg`);
  await mkdir(outDir, { recursive: true });

  try {
    await readFile(outPath);
  } catch {
    await execFileAsync("sips", [
      "-Z",
      String(maxSize),
      "-s",
      "format",
      "jpeg",
      "-s",
      "formatOptions",
      String(jpegQuality),
      sourcePath,
      "--out",
      outPath
    ]);
  }

  return {
    path: outPath,
    mimeType: "image/jpeg",
    cacheConfig: `${config.mode}:${autoThresholdKb}:${maxSize}:${jpegQuality}`
  };
}

function mimeTypeFor(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".webp") return "image/webp";
  if (ext === ".heic") return "image/heic";
  if (ext === ".heif") return "image/heif";
  return "image/png";
}
