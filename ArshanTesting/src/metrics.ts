export interface RunMetrics {
  time_to_first_action: number;
  screenshots_per_task: number;
  actions_per_task: number;
  exploratory_actions_per_task: number;
  memory_hit_rate: number;
  memory_helped_rate: number;
  memory_misled_rate: number;
  repeat_failure_rate: number;
}

export interface ActionResult {
  action: string;
  exploratory: boolean;
  success: boolean;
  usedMemory: boolean;
  memoryHelped: boolean;
  memoryMisled: boolean;
}

export function calculateRunMetrics(input: {
  startedAtMs: number;
  firstActionAtMs: number;
  screenshots: number;
  actions: ActionResult[];
}): RunMetrics {
  const actions = input.actions;
  const memoryActions = actions.filter((action) => action.usedMemory);
  const repeatFailures = repeatedFailures(actions);

  return {
    time_to_first_action: input.firstActionAtMs - input.startedAtMs,
    screenshots_per_task: input.screenshots,
    actions_per_task: actions.length,
    exploratory_actions_per_task: actions.filter((action) => action.exploratory).length,
    memory_hit_rate: actions.length === 0 ? 0 : memoryActions.length / actions.length,
    memory_helped_rate: memoryActions.length === 0 ? 0 : memoryActions.filter((action) => action.memoryHelped).length / memoryActions.length,
    memory_misled_rate: memoryActions.length === 0 ? 0 : memoryActions.filter((action) => action.memoryMisled).length / memoryActions.length,
    repeat_failure_rate: actions.length === 0 ? 0 : repeatFailures / actions.length
  };
}

function repeatedFailures(actions: ActionResult[]): number {
  const failed = new Set<string>();
  let repeats = 0;
  for (const action of actions) {
    if (!action.success) {
      if (failed.has(action.action)) repeats += 1;
      failed.add(action.action);
    }
  }
  return repeats;
}
