# Scenario B — Arc, open PR from recent_resources

**Tests:**
- Resolution of "the PR" → the GitHub URL in active_task.resources / recent_resources
- Brief leads with `open_url` (the fastest tool) rather than tab-switching navigation
- Active app is a browser → app_specific.tabs includes the PR as an inactive tab; either navigating to it or switching tabs would work, but `open_url` is preferred

**Setup:** User is on GitHub home in Arc. PR #1342 is one of their tabs and also
in active_task.resources + recent_resources. Mercury must:
1. Resolve "the PR" → the URL
2. Suggest `open_url https://github.com/co/repo/pull/1342` as step 1
3. Optionally mention the tab-switch alternative
