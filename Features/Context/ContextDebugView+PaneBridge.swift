import SwiftUI

extension ContextDebugView {
    var intentPane: some View { ContextDebugIntentView() }
    var dirtyPane: some View { ContextDebugDirtyPane() }
    var reportPane: some View { ContextDebugReportPane() }
    var harnessPane: some View { ContextDebugHarnessPane() }
}
