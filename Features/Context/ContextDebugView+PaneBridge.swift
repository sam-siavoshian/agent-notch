//
//  ContextDebugView+PaneBridge.swift
//  Agent in the Notch
//
//  Bridges standalone pane View structs (built by parallel agents) into the
//  ContextDebugView's expected `<name>Pane` extension property dispatch.
//

import SwiftUI

extension ContextDebugView {
    var aiPane: some View { ContextDebugAIView() }
    var intentPane: some View { ContextDebugIntentView() }
    var dirtyPane: some View { ContextDebugDirtyPane() }
    var cachePane: some View { ContextDebugCachePane() }
    var reportPane: some View { ContextDebugReportPane() }
}
