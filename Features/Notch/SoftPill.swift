//
//  SoftPill.swift
//  Agent in the Notch
//
//  Dark-adapted soft-pill design system, sized compact for the notch.
//

import SwiftUI

// MARK: – Tokens

enum SoftPill {
    enum Canvas {
        static let base = Color(red: 0x0F / 255, green: 0x0F / 255, blue: 0x12 / 255)
    }
    enum Surface {
        static let base   = Color(red: 0x1C / 255, green: 0x1D / 255, blue: 0x22 / 255)
        static let raised = Color(red: 0x22 / 255, green: 0x23 / 255, blue: 0x29 / 255)
        static let hover  = Color(red: 0x26 / 255, green: 0x27 / 255, blue: 0x2D / 255)
        static let inset  = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1B / 255)
    }
    enum Text {
        static let primary   = Color.white.opacity(0.92)
        static let secondary = Color.white.opacity(0.55)
        static let muted     = Color.white.opacity(0.32)
    }
    enum Border {
        static let subtle  = Color.white.opacity(0.06)
    }
    enum Status {
        static let amber = Color(red: 0xF5 / 255, green: 0xB9 / 255, blue: 0x47 / 255)
        static let blue  = Color(red: 0x5B / 255, green: 0x7C / 255, blue: 0xFA / 255)
        static let green = Color(red: 0x7D / 255, green: 0xD4 / 255, blue: 0x9A / 255)
        static let red   = Color(red: 0xF3 / 255, green: 0x7A / 255, blue: 0x7A / 255)
        static let gray  = Color(red: 0xB5 / 255, green: 0xB8 / 255, blue: 0xBF / 255)
    }
    enum CTA {
        static let from = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0xB6 / 255)
        static let to   = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x6B / 255)
        static let gradient = LinearGradient(
            colors: [from, to],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func activityHue(_ activity: AgentActivity) -> Color {
        switch activity {
        case .idle:      return Status.gray
        case .listening: return Status.blue
        case .thinking:  return Status.amber
        case .toolCall:  return Status.green
        case .error:     return Status.red
        }
    }
}

// MARK: – Pill background recipe

struct PillBackground: View {
    var fill: AnyShapeStyle = AnyShapeStyle(SoftPill.Surface.raised)
    /// Hover glow tint. Currently unused (callers never activate hover) but
    /// kept as a parameter so external call sites remain source-compatible.
    var glow: Color? = nil
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let shape: AnyShape = cornerRadius.map {
            AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous))
        } ?? AnyShape(Capsule(style: .continuous))

        ZStack {
            shape.fill(fill)

            shape
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                .blur(radius: 0.5)
                .mask(
                    shape.fill(LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .top,
                        endPoint: .center
                    ))
                )
        }
        .overlay(shape.stroke(SoftPill.Border.subtle, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 9, x: 0, y: 4)
    }
}

// MARK: – Status badge

struct StatusBadge: View {
    let color: Color
    let symbol: String
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: color.opacity(0.5), radius: 3)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: – Ghost pill

struct GhostPill<Content: View>: View {
    var tint: Color = SoftPill.Text.muted
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.55),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
    }
}

// MARK: – Toolbar

struct PillToolbar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(PillBackground(fill: AnyShapeStyle(SoftPill.Surface.base)))
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    var label: String? = nil
    var isActive: Bool = false
    var tint: Color? = nil
    var action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(tint ?? (isActive ? SoftPill.Text.primary : SoftPill.Text.secondary))
            .padding(.horizontal, label == nil ? 6 : 8)
            .padding(.vertical, 4)
            .frame(minHeight: 20)
            .background(
                ZStack {
                    if isActive {
                        Capsule(style: .continuous)
                            .fill(SoftPill.Surface.inset)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.black.opacity(0.35), lineWidth: 0.7)
                                    .blur(radius: 0.5)
                                    .mask(
                                        Capsule(style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [.white, .clear],
                                                startPoint: .top,
                                                endPoint: .center
                                            ))
                                    )
                            )
                    } else if hovered {
                        Capsule(style: .continuous)
                            .fill(SoftPill.Surface.hover)
                    }
                }
            )
            .scaleEffect(pressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.14), value: hovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.78), value: pressed)
    }
}

// MARK: – Swatch button

struct SwatchPillButton: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.15),
                            lineWidth: isSelected ? 1.8 : 1
                        )
                )
                .shadow(color: color.opacity(hovered || isSelected ? 0.6 : 0.2),
                        radius: hovered || isSelected ? 6 : 2)
                .scaleEffect(hovered ? 1.08 : 1.0)
                .padding(2)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: hovered)
    }
}
