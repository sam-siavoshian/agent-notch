//
//  NotchShape.swift
//  Agent in the Notch
//
//  A pill-with-flat-top — straight along the top edge (flush with the menu
//  bar), rounded along the bottom. The physical notch sits inside; the
//  background is opaque black so the carve-out is invisible.
//

import SwiftUI

struct NotchShape: Shape {
    var bottomCornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomCornerRadius, rect.width / 2, rect.height)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}
