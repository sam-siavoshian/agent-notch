# Scenario A — Send Slack DM with person from L5

**Tests:**
- Resolution of "the latest draft" → the Figma file in active_task.resources
- Resolution of "maya" → the person entity in active_task.entities
- Use of L3 recipe "open DM with person" (seen_count 7) to lead the brief
- Use of recent clipboard URL (12s old) as the message body
- No pixel coordinates

**Setup:** User is in Slack #design channel composer (not yet in a DM). Maya is in
participants list and in active_task.entities. The Figma URL is in clipboard
(just copied) and in recent_resources. Mercury must:
1. Recognize "send" as the verb and resolve "the latest draft" to the Figma file
2. Suggest opening DM with Maya first (cmd+K → "maya" → return) since we're in a channel
3. Then paste the URL (or use it directly from recent_resources)
