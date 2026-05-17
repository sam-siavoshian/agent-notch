//
//  LucideIcons.swift
//  Agent in the Notch
//
//  Standard SF Symbols. No custom path math, no animation states.
//  API kept stable so call sites do not need to change.
//

import SwiftUI

enum LucideName {
    case accessibility
    case monitor
    case mic
    case keyboard
    case sparkles
    case rotateCW
    case settings
    case check
    case xmark
    case info
}

struct LucideIcon: View {
    let name: LucideName
    var size: CGFloat = 20
    var lineWidth: CGFloat = 2
    var animate: Bool = false
    var trigger: AnyHashable? = nil

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size, weight: weight))
            .frame(width: size, height: size)
    }

    private var symbolName: String {
        switch name {
        case .accessibility: return "figure.arms.open"
        case .monitor:       return "display"
        case .mic:           return "mic.fill"
        case .keyboard:      return "keyboard"
        case .sparkles:      return "sparkles"
        case .rotateCW:      return "arrow.clockwise"
        case .settings:      return "gearshape.fill"
        case .check:         return "checkmark"
        case .xmark:         return "xmark"
        case .info:          return "info.circle"
        }
    }

    private var weight: Font.Weight {
        if lineWidth >= 2.4 { return .bold }
        if lineWidth >= 2.0 { return .semibold }
        return .medium
    }
}
