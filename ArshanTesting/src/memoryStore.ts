import { mkdir, readFile, writeFile, appendFile } from "node:fs/promises";
import path from "node:path";
import { Observation } from "./observationPrompt";
import { SimulatedAction } from "./memoryUpdatePrompt";
import { projectRoot } from "./syntheticScreens";

export interface AppMemory {
  app: string;
  profile: string;
  surfaces: MemoryFact[];
  landmarks: MemoryFact[];
  affordances: MemoryFact[];
  transitions: MemoryTransition[];
  taskRecipes: MemoryFact[];
  negativeMemory: MemoryFact[];
  uncertainNotes: MemoryFact[];
}

export interface MemoryFact {
  text: string;
  confidence: "low" | "medium" | "high";
  evidenceIds: string[];
}

export interface MemoryTransition {
  fromSurface: string;
  action: string;
  toSurface: string;
  confidence: "low" | "medium" | "high";
  evidenceIds: string[];
}

export class MemoryStore {
  readonly rootDir: string;

  constructor(rootDir = projectRoot()) {
    this.rootDir = rootDir;
  }

  async ensure(): Promise<void> {
    await mkdir(path.join(this.rootDir, "memory", "apps"), { recursive: true });
    await mkdir(path.join(this.rootDir, "memory", "cache"), { recursive: true });
    await writeFile(path.join(this.rootDir, "memory", "observations.jsonl"), "", { flag: "a" });
  }

  async appendObservation(observation: Observation): Promise<void> {
    await this.ensure();
    const filePath = path.join(this.rootDir, "memory", "observations.jsonl");
    await appendFile(filePath, `${JSON.stringify(observation)}\n`, "utf8");
  }

  async readObservations(): Promise<Observation[]> {
    const filePath = path.join(this.rootDir, "memory", "observations.jsonl");
    try {
      const raw = await readFile(filePath, "utf8");
      return raw.split("\n").filter(Boolean).map((line) => JSON.parse(line) as Observation);
    } catch {
      return [];
    }
  }

  async readAppMemory(app: string): Promise<AppMemory | undefined> {
    const filePath = this.jsonPath(app);
    try {
      return JSON.parse(await readFile(filePath, "utf8")) as AppMemory;
    } catch {
      return undefined;
    }
  }

  async writeAppMemory(memory: AppMemory): Promise<void> {
    await this.ensure();
    await writeFile(this.jsonPath(memory.app), JSON.stringify(memory, null, 2), "utf8");
    await writeFile(this.markdownPath(memory.app), renderAppMemoryMarkdown(memory), "utf8");
  }

  jsonPath(app: string): string {
    return path.join(this.rootDir, "memory", "apps", `${slug(app)}.json`);
  }

  markdownPath(app: string): string {
    return path.join(this.rootDir, "memory", "apps", `${slug(app)}.md`);
  }
}

export function emptyAppMemory(app: string): AppMemory {
  return {
    app,
    profile: `${app} is a synthetic SaaS deployment dashboard used to test UI/UX learning.`,
    surfaces: [],
    landmarks: [],
    affordances: [],
    transitions: [],
    taskRecipes: [],
    negativeMemory: [],
    uncertainNotes: []
  };
}

export function updateMemoryFromObservations(
  observations: Observation[],
  actions: SimulatedAction[],
  existing?: AppMemory
): AppMemory {
  const app = observations[0]?.app ?? existing?.app ?? "Unknown App";
  const memory = cloneMemory(existing ?? emptyAppMemory(app));

  for (const observation of observations) {
    addFact(memory.surfaces, `${observation.surfaceLabel}: ${observation.summary}`, "high", [observation.id]);

    for (const landmark of observation.landmarks) {
      addFact(memory.landmarks, landmark, observation.confidence > 0.9 ? "high" : "medium", [observation.id]);
    }

    for (const affordance of observation.likelyAffordances) {
      addFact(memory.affordances, affordance, observation.confidence > 0.9 ? "high" : "medium", [observation.id]);
    }

    for (const uncertainty of observation.uncertainty) {
      addFact(memory.uncertainNotes, uncertainty, "medium", [observation.id]);
    }
  }

  for (const action of actions) {
    const before = observations.find((observation) => observation.surfaceId === action.from);
    const after = observations.find((observation) => observation.surfaceId === action.to);
    const evidenceIds = [before?.id, after?.id].filter(Boolean) as string[];

    if (action.success) {
      addTransition(memory.transitions, {
        fromSurface: action.from,
        action: action.action,
        toSurface: action.to,
        confidence: "high",
        evidenceIds
      });
    } else {
      addFact(memory.negativeMemory, `${action.action}: ${action.note}`, "high", evidenceIds);
    }
  }

  addFact(
    memory.taskRecipes,
    "Find failed deployment: open Deployments, use Status filter, select Failed, then inspect the failed deployment detail.",
    "high",
    observations.map((observation) => observation.id)
  );

  return memory;
}

export function renderAppMemoryMarkdown(memory: AppMemory): string {
  return [
    `# ${memory.app} UI Memory`,
    "",
    "## App Profile",
    memory.profile,
    "",
    renderFacts("Surfaces Seen", memory.surfaces),
    renderFacts("Landmarks", memory.landmarks),
    renderFacts("Affordances", memory.affordances),
    renderTransitions(memory.transitions),
    renderFacts("Task Recipes", memory.taskRecipes),
    renderFacts("Negative Memory", memory.negativeMemory),
    renderFacts("Stale / Uncertain Notes", memory.uncertainNotes)
  ].join("\n");
}

function renderFacts(title: string, facts: MemoryFact[]): string {
  const lines = [`## ${title}`];
  if (facts.length === 0) {
    lines.push("- None yet.");
  } else {
    for (const fact of facts) {
      lines.push(`- [${fact.confidence}] ${fact.text} (evidence: ${fact.evidenceIds.join(", ")})`);
    }
  }
  lines.push("");
  return lines.join("\n");
}

function renderTransitions(transitions: MemoryTransition[]): string {
  const lines = ["## Transitions"];
  if (transitions.length === 0) {
    lines.push("- None yet.");
  } else {
    for (const transition of transitions) {
      lines.push(`- [${transition.confidence}] ${transition.fromSurface} -- ${transition.action} --> ${transition.toSurface} (evidence: ${transition.evidenceIds.join(", ")})`);
    }
  }
  lines.push("");
  return lines.join("\n");
}

function addFact(facts: MemoryFact[], text: string, confidence: MemoryFact["confidence"], evidenceIds: string[]): void {
  const normalized = normalize(text);
  const existing = facts.find((fact) => normalize(fact.text) === normalized);
  if (existing) {
    existing.evidenceIds = Array.from(new Set([...existing.evidenceIds, ...evidenceIds]));
    existing.confidence = stronger(existing.confidence, confidence);
    return;
  }
  facts.push({ text, confidence, evidenceIds: Array.from(new Set(evidenceIds)) });
}

function addTransition(transitions: MemoryTransition[], transition: MemoryTransition): void {
  const existing = transitions.find((candidate) =>
    candidate.fromSurface === transition.fromSurface &&
    candidate.toSurface === transition.toSurface &&
    normalize(candidate.action) === normalize(transition.action)
  );
  if (existing) {
    existing.evidenceIds = Array.from(new Set([...existing.evidenceIds, ...transition.evidenceIds]));
    existing.confidence = stronger(existing.confidence, transition.confidence);
    return;
  }
  transitions.push(transition);
}

function stronger(a: MemoryFact["confidence"], b: MemoryFact["confidence"]): MemoryFact["confidence"] {
  const rank = { low: 0, medium: 1, high: 2 };
  return rank[b] > rank[a] ? b : a;
}

function normalize(value: string): string {
  return value.toLowerCase().replace(/\s+/g, " ").trim();
}

function slug(value: string): string {
  return normalize(value).replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

function cloneMemory(memory: AppMemory): AppMemory {
  return JSON.parse(JSON.stringify(memory)) as AppMemory;
}
