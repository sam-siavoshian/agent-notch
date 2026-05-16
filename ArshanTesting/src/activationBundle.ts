import { AppMemory, canonicalSurfaceKey, MemoryFact, MemoryTransition } from "./memoryStore";
import { Observation } from "./observationPrompt";

export interface ActivationBundle {
  userGoal: string;
  liveContext: {
    app: string;
    windowTitle: string;
    surfaceKey: string;
    surfaceLabel: string;
    summary: string;
    visibleControls: Observation["visibleControls"];
    visibleEntities: string[];
    uncertainty: string[];
    screenshotPath?: string;
  };
  recentActivity: string[];
  currentSurfaceMemory: MemoryFact[];
  relevantAffordances: MemoryFact[];
  relevantTransitions: MemoryTransition[];
  relevantTaskRecipes: MemoryFact[];
  negativeMemory: MemoryFact[];
  staleOrUncertainNotes: MemoryFact[];
  firstActionHint: string;
}

export function buildActivationBundle(input: {
  userGoal: string;
  observation: Observation;
  memory?: AppMemory;
  recentActivity?: string[];
}): ActivationBundle {
  const surfaceKey = canonicalSurfaceKey(input.observation);
  const goalTerms = importantTerms(input.userGoal);
  const currentSurfaceMemory = input.memory?.surfaces
    .filter((fact) => fact.text.startsWith(`[${surfaceKey}]`) || mentionsAny(fact.text, [surfaceKey, ...input.observation.landmarks]))
    .slice(0, 4) ?? [];
  const relevantAffordances = input.memory?.affordances
    .filter((fact) => mentionsAny(fact.text, goalTerms) || mentionsAny(fact.text, input.observation.likelyAffordances))
    .slice(0, 8) ?? [];
  const relevantTransitions = input.memory?.transitions
    .filter((transition) => transition.fromSurface === surfaceKey || mentionsAny(transition.action, goalTerms))
    .slice(0, 6) ?? [];
  const relevantTaskRecipes = input.memory?.taskRecipes
    .filter((fact) => mentionsAny(fact.text, goalTerms))
    .slice(0, 3) ?? [];
  const negativeMemory = input.memory?.negativeMemory
    .filter((fact) => mentionsAny(fact.text, [surfaceKey, ...goalTerms]) || fact.text.toLowerCase().includes("blank"))
    .slice(0, 5) ?? [];
  const staleOrUncertainNotes = [
    ...(input.memory?.uncertainNotes ?? []),
    ...input.observation.uncertainty.map((text): MemoryFact => ({
      text,
      confidence: "medium",
      evidenceIds: [input.observation.id]
    }))
  ].slice(0, 6);

  return {
    userGoal: input.userGoal,
    liveContext: {
      app: input.observation.app,
      windowTitle: input.observation.windowTitle,
      surfaceKey,
      surfaceLabel: input.observation.surfaceLabel,
      summary: input.observation.summary,
      visibleControls: input.observation.visibleControls,
      visibleEntities: input.observation.visibleEntities,
      uncertainty: input.observation.uncertainty,
      screenshotPath: input.observation.screenshotPath
    },
    recentActivity: input.recentActivity ?? [],
    currentSurfaceMemory,
    relevantAffordances,
    relevantTransitions,
    relevantTaskRecipes,
    negativeMemory,
    staleOrUncertainNotes,
    firstActionHint: firstActionHint(surfaceKey, relevantTransitions, relevantTaskRecipes, input.observation)
  };
}

function firstActionHint(
  surfaceKey: string,
  transitions: MemoryTransition[],
  recipes: MemoryFact[],
  observation: Observation
): string {
  const transition = transitions.find((candidate) => candidate.fromSurface === surfaceKey);
  if (transition) return transition.action;

  const recipe = recipes[0]?.text.toLowerCase() ?? "";
  if (recipe.includes("deployments") && surfaceKey === "overview") {
    const deploymentsControl = observation.visibleControls.find((control) => control.label.toLowerCase().includes("deployments"));
    return deploymentsControl ? `use visible control: ${deploymentsControl.label}` : "find Deployments navigation";
  }

  return "inspect visible controls and choose the first task-relevant action";
}

function importantTerms(goal: string): string[] {
  const terms = goal
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((term) => term.length > 2 && !["the", "and", "for", "with", "into"].includes(term));
  return Array.from(new Set(terms));
}

function mentionsAny(text: string, needles: string[]): boolean {
  const lower = text.toLowerCase();
  return needles.some((needle) => lower.includes(needle.toLowerCase()));
}
