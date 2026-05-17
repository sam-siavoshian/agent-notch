# active_task_updater / archive-and-new

**Trigger condition.** A CURRENT active_task exists (Figma design work). New
events show a clean domain switch: user opens iTerm2, runs `git status`, then
switches to VSCode editing `ActiveTaskUpdater.swift`. New apps, new resources,
completely different topic.

**What we're testing.** Mercury must return `{archive_and_start_new: {...}}`
rather than try to stretch the design task to cover coding work. The response
must:

- archive the Figma task with an outcome that references Figma / the design
  work just completed
- start a new task labeled with the new project (agent-notch) and kind in the
  coding family
- the new narrative must mention concrete signals from the new domain (VSCode,
  the file being edited)
- new resources must include the file URI

This tests the topic-shift detection — the model needs to recognize "user is
now doing something entirely different" rather than concatenating.
