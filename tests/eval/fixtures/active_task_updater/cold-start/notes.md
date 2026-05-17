# active_task_updater / cold-start

**Trigger condition.** No CURRENT active_task exists. The user has just switched
to Figma, dwelled deeply on the Onboarding v3 file, and started editing copy on
Step 1.

**What we're testing.** Mercury must produce a `{update: ...}` shape (NOT
`archive_and_start_new`, since there's nothing to archive) and the new task
object must:

- have a label that names both the app (Figma) and the work (Onboarding)
- pick a kind in the design family (`design_iteration` or `design_work`)
- write a narrative that references the concrete surface (Step 1) and app
- include the Figma file URI in `resources`

This is the bootstrap case — the model must invent a coherent task from raw
events without any prior context to lean on.
