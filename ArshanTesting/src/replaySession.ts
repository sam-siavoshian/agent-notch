import { copyFile, mkdir, mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { observeScreenshotWithGemini } from "./geminiClient";
import { calculateRunMetrics, ActionResult, RunMetrics } from "./metrics";
import { MemoryStore, updateMemoryFromObservations, AppMemory } from "./memoryStore";
import { Observation } from "./observationPrompt";
import { recognizeState, RecognitionResult } from "./recognitionPrompt";
import { generateSyntheticScreens, projectRoot, screenshotPathForState, syntheticStates, SyntheticStateId } from "./syntheticScreens";
import { SimulatedAction } from "./memoryUpdatePrompt";

const TASK = "Find the failed deployment in the deployment dashboard.";

const firstRunActions: SimulatedAction[] = [
  { from: "overview", action: "click blank center area", to: "overview", success: false, note: "Blank center area is not actionable." },
  { from: "overview", action: "click Deployments in the left navigation", to: "deployments", success: true, note: "Opens deployments table." },
  { from: "deployments", action: "click Status filter", to: "filters-open", success: true, note: "Opens filter panel." },
  { from: "filters-open", action: "select Failed status", to: "failed-detail", success: true, note: "Narrows to failed deployment and opens detail." }
];

const secondRunActions: SimulatedAction[] = [
  { from: "overview", action: "click Deployments in the left navigation", to: "deployments", success: true, note: "Uses learned navigation path." },
  { from: "deployments", action: "click Status filter", to: "filters-open", success: true, note: "Uses learned filter affordance." },
  { from: "filters-open", action: "select Failed status", to: "failed-detail", success: true, note: "Uses learned failed deployment recipe." }
];

export interface ReplayRunResult {
  label: "first-run" | "second-run";
  observations: Observation[];
  recognitions: RecognitionResult[];
  actions: ActionResult[];
  metrics: RunMetrics;
  memory?: AppMemory;
}

export interface ReplayDemoResult {
  firstRun: ReplayRunResult;
  secondRun: ReplayRunResult;
  memory: AppMemory;
}

export async function runRepeatedTaskDemo(options: {
  rootDir?: string;
  writeMemory?: boolean;
  liveGemini?: boolean;
} = {}): Promise<ReplayDemoResult> {
  const rootDir = options.rootDir ?? projectRoot();
  await generateSyntheticScreens(rootDir);
  const store = new MemoryStore(rootDir);
  await store.ensure();

  const firstRun = await runScenario({
    label: "first-run",
    rootDir,
    actions: firstRunActions,
    memory: undefined,
    liveGemini: options.liveGemini
  });

  const learnedMemory = updateMemoryFromObservations(firstRun.observations, firstRunActions);
  if (options.writeMemory ?? true) {
    for (const observation of firstRun.observations) {
      await store.appendObservation(observation);
    }
    await store.writeAppMemory(learnedMemory);
  }

  const secondRun = await runScenario({
    label: "second-run",
    rootDir,
    actions: secondRunActions,
    memory: learnedMemory,
    liveGemini: options.liveGemini
  });

  return {
    firstRun,
    secondRun,
    memory: learnedMemory
  };
}

async function runScenario(input: {
  label: ReplayRunResult["label"];
  rootDir: string;
  actions: SimulatedAction[];
  memory?: AppMemory;
  liveGemini?: boolean;
}): Promise<ReplayRunResult> {
  const startedAtMs = input.label === "first-run" ? 0 : 1000;
  const firstActionAtMs = input.label === "first-run" ? 620 : 1120;
  const stateOrder = uniqueStates(["overview", ...input.actions.map((action) => action.to)] as SyntheticStateId[]);
  const observations: Observation[] = [];
  const recognitions: RecognitionResult[] = [];

  for (const state of stateOrder) {
    const screenshotPath = screenshotPathForState(input.rootDir, state);
    const observation = await observeScreenshotWithGemini(screenshotPath, {
      rootDir: input.rootDir,
      stateHint: state,
      live: input.liveGemini
    });
    observations.push(observation);
    recognitions.push(recognizeState(observation, input.memory, TASK));
  }

  const actionResults: ActionResult[] = input.actions.map((action) => ({
    action: action.action,
    exploratory: input.label === "first-run" && (!action.success || action.action.includes("blank")),
    success: action.success,
    usedMemory: input.label === "second-run",
    memoryHelped: input.label === "second-run" && action.success,
    memoryMisled: false
  }));

  return {
    label: input.label,
    observations,
    recognitions,
    actions: actionResults,
    metrics: calculateRunMetrics({
      startedAtMs,
      firstActionAtMs,
      screenshots: observations.length,
      actions: actionResults
    }),
    memory: input.memory
  };
}

function uniqueStates(states: SyntheticStateId[]): SyntheticStateId[] {
  return Array.from(new Set(states));
}

export async function runDemoInTemp(): Promise<ReplayDemoResult> {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), "arshan-ui-learning-"));
  await copyCommittedScreenshots(tempRoot);
  return runRepeatedTaskDemo({ rootDir: tempRoot, writeMemory: true, liveGemini: false });
}

async function copyCommittedScreenshots(tempRoot: string): Promise<void> {
  const sourceRoot = projectRoot();
  const targetDir = path.join(tempRoot, "fixtures", "screenshots");
  await mkdir(targetDir, { recursive: true });
  for (const state of syntheticStates) {
    await copyFile(
      path.join(sourceRoot, "fixtures", "screenshots", state.fileName),
      path.join(targetDir, state.fileName)
    );
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  runRepeatedTaskDemo({ writeMemory: true, liveGemini: process.env.ARSHAN_LIVE_GEMINI === "1" })
    .then((result) => {
      console.log(JSON.stringify({
        firstRun: result.firstRun.metrics,
        secondRun: result.secondRun.metrics,
        memorySurfaces: result.memory.surfaces.length,
        memoryTransitions: result.memory.transitions.length,
        negativeMemories: result.memory.negativeMemory.length
      }, null, 2));
    })
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
}
