import { Observation } from "./observationPrompt";

export interface SimulatedAction {
  from: string;
  action: string;
  to: string;
  success: boolean;
  note: string;
}

export function buildMemoryUpdatePrompt(input: {
  before: Observation;
  after: Observation;
  action: SimulatedAction;
  currentMemoryMarkdown?: string;
}): string {
  return [
    "Update durable UI memory for a computer-use agent.",
    "Only store facts that would help operate the same app later.",
    "Prefer landmarks, affordances, transitions, task recipes, and negative memory.",
    "Do not store incidental row contents unless they explain the task.",
    "",
    "CURRENT MEMORY:",
    input.currentMemoryMarkdown ?? "(empty)",
    "",
    "BEFORE:",
    JSON.stringify(input.before, null, 2),
    "",
    "ACTION:",
    JSON.stringify(input.action, null, 2),
    "",
    "AFTER:",
    JSON.stringify(input.after, null, 2),
    "",
    "Return a concise memory patch."
  ].join("\n");
}
