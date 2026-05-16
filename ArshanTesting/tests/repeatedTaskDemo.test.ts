import { describe, expect, it } from "vitest";
import { runDemoInTemp } from "../src/replaySession";

describe("repeated task demo", () => {
  it("uses learned memory to reduce exploration on the second run", async () => {
    const result = await runDemoInTemp();

    expect(result.firstRun.metrics.actions_per_task).toBeGreaterThan(result.secondRun.metrics.actions_per_task);
    expect(result.firstRun.metrics.exploratory_actions_per_task).toBeGreaterThan(result.secondRun.metrics.exploratory_actions_per_task);
    expect(result.firstRun.metrics.memory_hit_rate).toBe(0);
    expect(result.secondRun.metrics.exploratory_actions_per_task).toBe(0);
    expect(result.secondRun.metrics.memory_hit_rate).toBe(1);
    expect(result.secondRun.metrics.memory_helped_rate).toBe(1);
    expect(result.secondRun.metrics.memory_misled_rate).toBe(0);
    expect(result.memory.negativeMemory.some((fact) => fact.text.includes("blank center"))).toBe(true);
  });
});
