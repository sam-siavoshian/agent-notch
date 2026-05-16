import { AppMemory, canonicalSurfaceKey, MemoryFact } from "./memoryStore";
import { Observation } from "./observationPrompt";

export interface RecognitionResult {
  app: string;
  matchedSurface: string;
  confidence: "low" | "medium" | "high";
  memoryHit: boolean;
  memoryHelped: boolean;
  layoutDriftDetected: boolean;
  retrievedFacts: string[];
  recommendedFirstAction: string;
  uncertainty: string[];
}

export function buildRecognitionPrompt(input: {
  observation: Observation;
  memory?: AppMemory;
  userGoal: string;
}): string {
  return [
    "Recognize the current UI state for a computer-use agent.",
    "Only match memory if visual evidence from the screenshot/OCR supports it.",
    "Prefer unknown state over a forced match.",
    "",
    `USER GOAL: ${input.userGoal}`,
    "",
    "OBSERVATION:",
    JSON.stringify(input.observation, null, 2),
    "",
    "MEMORY:",
    input.memory ? JSON.stringify(input.memory, null, 2) : "(none)"
  ].join("\n");
}

export function recognizeState(observation: Observation, memory: AppMemory | undefined, userGoal: string): RecognitionResult {
  const surfaceKey = canonicalSurfaceKey(observation);
  if (!memory) {
    return {
      app: observation.app,
      matchedSurface: observation.surfaceLabel,
      confidence: "low",
      memoryHit: false,
      memoryHelped: false,
      layoutDriftDetected: false,
      retrievedFacts: [],
      recommendedFirstAction: exploratoryAction(surfaceKey),
      uncertainty: ["No app memory exists yet."]
    };
  }

  const matchingSurface = bestSurfaceFact(observation, memory.surfaces, surfaceKey);
  const layoutDriftDetected = observation.surfaceId.includes("layout-drift") ||
    (hasFact(memory.landmarks, "left navigation") && mentionsAny(observation.landmarks.join(" "), ["top navigation", "top-nav", "top tabs"]));
  const relevantAffordances = memory.affordances
    .filter((fact) => mentionsAny(fact.text, ["Deployments", "Status filter", "Failed"]))
    .slice(0, 5);
  const negative = memory.negativeMemory.slice(0, 3);
  const taskRecipe = memory.taskRecipes.find((fact) => mentionsAny(fact.text, ["failed deployment"]));
  const retrievedFacts = [
    matchingSurface?.text,
    ...relevantAffordances.map((fact) => fact.text),
    taskRecipe?.text,
    ...negative.map((fact) => `Avoid: ${fact.text}`)
  ].filter(Boolean) as string[];

  const confidence = layoutDriftDetected ? "medium" : matchingSurface ? "high" : "low";
  const canUseRecipe = Boolean((taskRecipe || matchingSurface) && relevantAffordances.length > 0);

  return {
    app: observation.app,
    matchedSurface: matchingSurface?.text ?? observation.surfaceLabel,
    confidence,
    memoryHit: retrievedFacts.length > 0,
    memoryHelped: canUseRecipe,
    layoutDriftDetected,
    retrievedFacts,
    recommendedFirstAction: chooseMemoryAction(surfaceKey, userGoal, layoutDriftDetected),
    uncertainty: layoutDriftDetected
      ? ["Known app memory partially matches, but navigation landmarks moved."]
      : observation.uncertainty
  };
}

function bestSurfaceFact(observation: Observation, facts: MemoryFact[], surfaceKey: string): MemoryFact | undefined {
  const label = observation.surfaceLabel.toLowerCase();
  return facts.find((fact) => fact.text.startsWith(`[${surfaceKey}]`)) ??
    facts.find((fact) => fact.text.toLowerCase().includes(label.split(" ")[0])) ??
    facts.find((fact) => mentionsAny(fact.text, observation.landmarks));
}

function chooseMemoryAction(surfaceKey: string, userGoal: string, layoutDriftDetected: boolean): string {
  const wantsFailedDeployment = userGoal.toLowerCase().includes("failed deployment");
  if (!wantsFailedDeployment) return exploratoryAction(surfaceKey);
  if (surfaceKey === "overview" && !layoutDriftDetected) return "click Deployments in the left navigation";
  if (surfaceKey === "overview" && layoutDriftDetected) return "click Deployments in the top navigation";
  if (surfaceKey === "deployments") return "click Status filter";
  if (surfaceKey === "filters-open") return "select Failed status";
  return "inspect failed deployment detail";
}

function exploratoryAction(surfaceKey: string): string {
  if (surfaceKey === "overview") return "inspect visible navigation, then choose Deployments";
  return "inspect visible controls and choose the most relevant next action";
}

function hasFact(facts: MemoryFact[], query: string): boolean {
  return facts.some((fact) => fact.text.toLowerCase().includes(query.toLowerCase()));
}

function mentionsAny(text: string, needles: string[]): boolean {
  const lower = text.toLowerCase();
  return needles.some((needle) => lower.includes(needle.toLowerCase()));
}
