# Scenario C — iTerm run tests with cwd context

**Tests:**
- Use of TerminalAdapter `cwd` from `app_specific` to scope the shell command
- L3 recipe `run swift package tests` matches and is rendered as a `shell_cmd` step
- Brief mentions both the command and the cwd (so the agent knows where to run it)
- No pixel coordinates

**Setup:** User is in iTerm in the project root. Recent commands show git activity.
There's an L3 recipe for `swift test`. Mercury must:
1. Resolve "the tests" → swift test in the current cwd
2. Suggest `swift test` as the shell_cmd, scoped to /Users/arshan/Desktop/tritonhacks2026
