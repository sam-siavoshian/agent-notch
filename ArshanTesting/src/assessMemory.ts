import { pathToFileURL } from "node:url";
import { AppMemory, canonicalSurfaceKey, MemoryStore } from "./memoryStore";
import { Observation } from "./observationPrompt";
import { projectRoot } from "./syntheticScreens";

interface MemoryAssessment {
  app: string;
  passed: boolean;
  score: number;
  checks: AssessmentCheck[];
  takeaways: string[];
}

interface AssessmentCheck {
  name: string;
  passed: boolean;
  detail: string;
}

const expectedSurfaces = ["overview", "deployments", "filters-open", "failed-detail"];

export async function assessStoredMemory(rootDir = projectRoot(), app = "Acme Deploy"): Promise<MemoryAssessment> {
  const store = new MemoryStore(rootDir);
  const memory = await store.readAppMemory(app);
  const observations = await store.readObservations();
  if (!memory) {
    return {
      app,
      passed: false,
      score: 0,
      checks: [{ name: "memory file", passed: false, detail: `No app memory found for ${app}.` }],
      takeaways: ["Run npm run demo to generate a baseline memory artifact."]
    };
  }

  return assessMemory(memory, observations);
}

export function assessMemory(memory: AppMemory, observations: Observation[]): MemoryAssessment {
  const observedSurfaceKeys = new Set([
    ...memory.surfaces.map((fact) => bracketedSurfaceKey(fact.text)).filter(Boolean),
    ...observations.map((observation) => canonicalSurfaceKey(observation))
  ] as string[]);
  const missingSurfaces = expectedSurfaces.filter((surface) => !observedSurfaceKeys.has(surface));
  const emptyEvidenceTransitions = memory.transitions.filter((transition) => transition.evidenceIds.length < 2);
  const absolutePaths = observations
    .map((observation) => observation.screenshotPath)
    .filter((value): value is string => Boolean(value?.startsWith("/")));

  const checks: AssessmentCheck[] = [
    {
      name: "core surfaces",
      passed: missingSurfaces.length === 0,
      detail: missingSurfaces.length === 0
        ? "All expected dashboard surfaces are represented."
        : `Missing surfaces: ${missingSurfaces.join(", ")}.`
    },
    {
      name: "affordances",
      passed: memory.affordances.length >= 6,
      detail: `${memory.affordances.length} affordances captured.`
    },
    {
      name: "transitions with evidence",
      passed: memory.transitions.length >= 3 && emptyEvidenceTransitions.length === 0,
      detail: `${memory.transitions.length} transitions; ${emptyEvidenceTransitions.length} missing before/after evidence.`
    },
    {
      name: "task recipe",
      passed: memory.taskRecipes.some((fact) => fact.text.toLowerCase().includes("failed deployment")),
      detail: `${memory.taskRecipes.length} task recipes captured.`
    },
    {
      name: "negative memory",
      passed: memory.negativeMemory.some((fact) => fact.text.toLowerCase().includes("blank center")),
      detail: `${memory.negativeMemory.length} negative memory facts captured.`
    },
    {
      name: "uncertainty",
      passed: memory.uncertainNotes.length > 0,
      detail: `${memory.uncertainNotes.length} stale/uncertain notes captured.`
    },
    {
      name: "portable observations",
      passed: absolutePaths.length === 0,
      detail: absolutePaths.length === 0
        ? "Observation screenshot paths are portable."
        : `${absolutePaths.length} absolute screenshot paths found.`
    }
  ];
  const passedCount = checks.filter((check) => check.passed).length;

  return {
    app: memory.app,
    passed: passedCount === checks.length,
    score: passedCount / checks.length,
    checks,
    takeaways: takeawaysFor(checks)
  };
}

function bracketedSurfaceKey(text: string): string | undefined {
  return /^\[([^\]]+)\]/.exec(text)?.[1];
}

function takeawaysFor(checks: AssessmentCheck[]): string[] {
  const failed = checks.filter((check) => !check.passed);
  if (failed.length === 0) {
    return [
      "The artifact is a useful controlled baseline for UI memory.",
      "Next layer: replace scripted action labels with before/after visual transition inference."
    ];
  }

  return failed.map((check) => {
    if (check.name === "transitions with evidence") return "Fix surface identity before trusting navigation lessons.";
    if (check.name === "portable observations") return "Scrub generated observations before committing shared artifacts.";
    if (check.name === "core surfaces") return "Run the full synthetic session before evaluating memory usefulness.";
    return `Improve ${check.name}: ${check.detail}`;
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  assessStoredMemory()
    .then((assessment) => {
      console.log(JSON.stringify(assessment, null, 2));
      if (!assessment.passed) process.exitCode = 1;
    })
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
}
