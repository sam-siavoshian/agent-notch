import Foundation

/// System prompt for the ActiveTaskUpdater Mercury call.
///
/// Copied verbatim from `Features/Context/ActiveTaskUpdater.swift` to support
/// fixture-based evaluation without the EvalHarness depending on the app
/// target. Phase 4 cleanup will dedupe by having the production code import
/// this constant.
public enum ActiveTaskUpdaterSystemPrompt {
    public static let text = """
    You maintain a structured Active Task object representing what the user is working on.

    You will receive:
      - CURRENT active_task: the current task object, or null if none exists
      - NEW events: a list of recent CEvent objects since the last update
      - RECENT resources: URIs the user has touched recently

    Return strictly one of these JSON shapes:

      { "update": { ...updated active_task fields... } }

      - OR -

      { "archive_and_start_new": {
          "ended_task": { ...the previous task with an "outcome" string added... },
          "new_task":   { ...complete new active_task object... }
        }
      }

    Use archive_and_start_new ONLY when the user has clearly switched domains
    (different apps, different resources, different topic). Otherwise update in place.
    Be specific in the narrative. Reference concrete actions, file names, channel names, people.
    """
}
