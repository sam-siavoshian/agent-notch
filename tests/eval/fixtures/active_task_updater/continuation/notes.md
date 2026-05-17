# active_task_updater / continuation

**Trigger condition.** A CURRENT active_task already exists (user iterating
Onboarding v3 in Figma, started at Step 1). New events show the user moving to
Step 2 in the same file and editing the helper text.

**What we're testing.** Mercury must update in place (`{update: ...}`) rather
than archive — same app, same file, adjacent work. The updated task object
must:

- keep the Onboarding label (work didn't change topic)
- stay in the design kind family
- expand the narrative to mention Step 2 progress
- expand `resources` to include the Step-2 frame URI

This tests the "stay coherent across micro-iteration" path — the most common
flow the user will actually see during a Figma session.
