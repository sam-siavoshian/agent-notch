//
//  ContextDebugView+PaneBridge.swift
//  Agent in the Notch
//
//  Bridges standalone pane View structs (built by parallel agents) into the
//  ContextDebugView's expected `<name>Pane` extension property dispatch.
//

import SwiftUI

extension ContextDebugView {
    var intentPane: some View { ContextDebugIntentView() }
    var dirtyPane: some View { ContextDebugDirtyPane() }
    var reportPane: some View { ContextDebugReportPane() }
    var harnessPane: some View { ContextDebugHarnessPane() }
}
