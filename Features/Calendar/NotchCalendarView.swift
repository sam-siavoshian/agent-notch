import EventKit
import SwiftUI

struct NotchCalendarView: View {
    @ObservedObject private var service = CalendarService.shared
    @State private var now: Date = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch service.authorizationStatus {
            case .fullAccess:
                authorizedView
            case .denied, .restricted:
                deniedView
            default:
                requestView
            }
        }
        .onReceive(ticker) { now = $0 }
        .frame(maxWidth: .infinity, idealHeight: 320, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Request access (editorial layout)

    private var requestView: some View {
        EditorialPermissionView(
            eyebrow: eyebrowDate,
            headlineTop: "Your week,",
            headlineBottom: "in the notch.",
            accent: SoftPill.Status.red,
            ctaLabel: "Connect Calendar",
            ctaIcon: "sparkles",
            ctaAction: { Task { await service.requestAccess() } },
            secondary: nil
        )
    }

    // MARK: - Denied

    private var deniedView: some View {
        EditorialPermissionView(
            eyebrow: eyebrowDate,
            headlineTop: "Calendar",
            headlineBottom: "is locked out.",
            accent: SoftPill.Status.amber,
            ctaLabel: "Open Settings",
            ctaIcon: "arrow.up.right",
            ctaAction: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            },
            secondary: "Enable Calendars under Privacy."
        )
    }

    private var eyebrowDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE • MMM d"
        return f.string(from: Date()).uppercased()
    }

    // MARK: - Authorized

    @ViewBuilder
    private var authorizedView: some View {
        if service.todayEvents.isEmpty && service.upcomingEvents.isEmpty {
            emptyView
        } else {
            eventsView
        }
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalendarHeader(date: now, todayCount: 0)
            WeekStrip(reference: now, accent: SoftPill.Status.green)
            HStack(spacing: 6) {
                Circle().fill(SoftPill.Status.green).frame(width: 5, height: 5)
                    .shadow(color: SoftPill.Status.green.opacity(0.8), radius: 3)
                Text("NOTHING ON THE BOOKS.")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(SoftPill.Text.muted)
                Spacer()
            }
            Text("Enjoy the quiet.")
                .font(.system(size: 18, design: .serif).italic())
                .foregroundStyle(SoftPill.Text.primary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Events list

    private var eventsView: some View {
        let buckets = classify(service.todayEvents, now: now)

        return VStack(alignment: .leading, spacing: 8) {
            CalendarHeader(date: now, todayCount: service.todayEvents.count)

            if let live = buckets.live {
                SectionLabel("HAPPENING NOW", accent: SoftPill.Status.green)
                EventCard(event: live, now: now, emphasis: .live)
            }

            if let next = buckets.next {
                SectionLabel("UP NEXT", accent: SoftPill.Status.blue)
                EventCard(event: next, now: now, emphasis: .next)
            }

            if !buckets.laterToday.isEmpty {
                SectionLabel("LATER TODAY", accent: SoftPill.Text.muted)
                ForEach(buckets.laterToday, id: \.eventIdentifier) { event in
                    EventCard(event: event, now: now, emphasis: .normal)
                }
            }

            if !buckets.past.isEmpty {
                SectionLabel("EARLIER", accent: SoftPill.Text.muted)
                ForEach(buckets.past, id: \.eventIdentifier) { event in
                    EventCard(event: event, now: now, emphasis: .past)
                }
            }

            if !service.upcomingEvents.isEmpty {
                SectionLabel("THIS WEEK", accent: SoftPill.Text.muted)
                ForEach(service.upcomingEvents.prefix(5), id: \.eventIdentifier) { event in
                    EventCard(event: event, now: now, emphasis: .future)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

// MARK: - Classification

private struct EventBuckets {
    var live: EKEvent?
    var next: EKEvent?
    var laterToday: [EKEvent]
    var past: [EKEvent]
}

private func classify(_ events: [EKEvent], now: Date) -> EventBuckets {
    var live: EKEvent?
    var next: EKEvent?
    var later: [EKEvent] = []
    var past: [EKEvent] = []

    let timed = events.filter { !$0.isAllDay }
    let allDay = events.filter { $0.isAllDay }

    for e in timed {
        if e.startDate <= now && e.endDate > now {
            if live == nil { live = e }
        } else if e.startDate > now {
            if next == nil { next = e } else { later.append(e) }
        } else {
            past.append(e)
        }
    }
    // All-day events live in "later today" unless already past midnight wraparound
    later.insert(contentsOf: allDay, at: 0)

    return EventBuckets(live: live, next: next, laterToday: later, past: past)
}

// MARK: - Header

private struct CalendarHeader: View {
    let date: Date
    let todayCount: Int

    var body: some View {
        HStack(spacing: 8) {
            DateTile(date: date, tint: SoftPill.Status.red, compact: true)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(weekday)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.primary)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SoftPill.Text.secondary)
            }
            Spacer(minLength: 0)

            CountChip(count: todayCount)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var weekday: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
    private var subtitle: String {
        let n = todayCount
        return n == 1 ? "1 event today" : "\(n) events today"
    }
}

private struct CountChip: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(SoftPill.Text.primary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(SoftPill.Surface.raised)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SoftPill.Border.subtle, lineWidth: 0.5)
                    )
            )
    }
}

private struct SectionLabel: View {
    let title: String
    let accent: Color
    init(_ title: String, accent: Color) { self.title = title; self.accent = accent }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 5, height: 5)
                .shadow(color: accent.opacity(0.7), radius: 3)
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(SoftPill.Text.muted)
            Rectangle().fill(SoftPill.Border.subtle).frame(height: 0.5)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

// MARK: - Date tile

private struct DateTile: View {
    let date: Date
    let tint: Color
    var compact: Bool = false
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(dimmed ? 0.35 : 0.95), tint.opacity(dimmed ? 0.2 : 0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: tint.opacity(dimmed ? 0.1 : 0.45), radius: compact ? 4 : 10, y: compact ? 2 : 4)

            VStack(spacing: compact ? 0 : 1) {
                Text(monthText)
                    .font(.system(size: compact ? 6.5 : 8.5, weight: .bold))
                    .tracking(compact ? 0.5 : 1)
                    .foregroundStyle(.white.opacity(0.95))
                Text(dayText)
                    .font(.system(size: compact ? 14 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }

    private var monthText: String {
        let f = DateFormatter(); f.dateFormat = "MMM"
        return f.string(from: date).uppercased()
    }
    private var dayText: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: date)
    }
}

// MARK: - Event card

private enum EventEmphasis { case live, next, normal, past, future }

private struct EventCard: View {
    let event: EKEvent
    let now: Date
    let emphasis: EventEmphasis

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            // Color stripe + dot
            ZStack(alignment: .top) {
                Capsule()
                    .fill(calendarColor.opacity(emphasis == .past ? 0.3 : 0.9))
                    .frame(width: 3)
                if emphasis == .live {
                    Circle()
                        .fill(calendarColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: calendarColor.opacity(0.8), radius: 4)
                        .offset(x: -2, y: -1)
                }
            }
            .frame(width: 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(event.title ?? "Untitled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)

                    if emphasis == .live {
                        LiveBadge()
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: event.isAllDay ? "sun.max.fill" : "clock.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.muted)
                    Text(timeText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(SoftPill.Text.secondary)

                    if let loc = locationText {
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(SoftPill.Text.muted)
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(SoftPill.Text.muted)
                        Text(loc)
                            .font(.system(size: 9.5))
                            .foregroundStyle(SoftPill.Text.secondary)
                            .lineLimit(1)
                    }
                }

                if emphasis == .live, let progress = liveProgress {
                    ProgressBar(progress: progress, tint: calendarColor)
                        .frame(height: 3)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 4)

            if let badge = trailingBadge {
                badge
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )
                .shadow(
                    color: emphasis == .live ? calendarColor.opacity(0.18) : Color.black.opacity(0.25),
                    radius: hovered ? 8 : 4,
                    y: hovered ? 4 : 2
                )
        )
        .scaleEffect(hovered ? 1.01 : 1.0)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .onTapGesture { openInCalendar() }
    }

    // MARK: tokens

    private var calendarColor: Color {
        if let cg = event.calendar?.cgColor { return Color(cgColor: cg) }
        return SoftPill.Status.blue
    }

    private var titleColor: Color {
        switch emphasis {
        case .past: return SoftPill.Text.secondary
        default: return SoftPill.Text.primary
        }
    }

    private var cardFill: Color {
        switch emphasis {
        case .live: return SoftPill.Surface.hover
        case .next: return SoftPill.Surface.raised
        case .past: return SoftPill.Surface.base.opacity(0.6)
        default: return SoftPill.Surface.raised
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .live: return calendarColor.opacity(0.45)
        case .next: return SoftPill.Border.subtle
        default: return SoftPill.Border.subtle
        }
    }

    // MARK: progress

    private var liveProgress: Double? {
        let total = event.endDate.timeIntervalSince(event.startDate)
        guard total > 0 else { return nil }
        let elapsed = now.timeIntervalSince(event.startDate)
        return max(0, min(1, elapsed / total))
    }

    // MARK: trailing badge (relative time)

    private var trailingBadge: AnyView? {
        switch emphasis {
        case .live:
            let remaining = event.endDate.timeIntervalSince(now)
            return AnyView(RelativeTimeChip(label: shortDuration(remaining) + " left",
                                            tint: SoftPill.Status.green,
                                            filled: true))
        case .next:
            let until = event.startDate.timeIntervalSince(now)
            return AnyView(RelativeTimeChip(label: "in " + shortDuration(until),
                                            tint: SoftPill.Status.blue,
                                            filled: true))
        case .normal:
            let until = event.startDate.timeIntervalSince(now)
            if until > 0, until < 60 * 60 * 6 {
                return AnyView(RelativeTimeChip(label: "in " + shortDuration(until),
                                                tint: SoftPill.Text.secondary,
                                                filled: false))
            }
            return nil
        case .future:
            return AnyView(RelativeTimeChip(label: dayLabel(event.startDate),
                                            tint: SoftPill.Text.secondary,
                                            filled: false))
        case .past:
            return nil
        }
    }

    // MARK: text

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter(); f.timeStyle = .short
        let start = f.string(from: event.startDate)
        let end = f.string(from: event.endDate)
        return "\(start) – \(end)"
    }

    private var locationText: String? {
        guard let loc = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else {
            return nil
        }
        return loc
    }

    private func openInCalendar() {
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Tiny components

private struct LiveBadge: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(SoftPill.Status.green)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 0.4 : 1)
                .shadow(color: SoftPill.Status.green.opacity(0.9), radius: 3)
            Text("LIVE")
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(SoftPill.Status.green)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(SoftPill.Status.green.opacity(0.14))
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct RelativeTimeChip: View {
    let label: String
    let tint: Color
    let filled: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(filled ? tint : SoftPill.Text.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(filled ? tint.opacity(0.16) : Color.clear)
                    .overlay(
                        Capsule().stroke(
                            filled ? tint.opacity(0.35) : SoftPill.Border.subtle,
                            lineWidth: 0.5
                        )
                    )
            )
    }
}

private struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.9), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * progress))
                    .shadow(color: tint.opacity(0.6), radius: 3)
            }
        }
    }
}

// MARK: - Buttons

private struct GradientPillButton: View {
    let label: String
    var icon: String? = nil
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(SoftPill.CTA.gradient)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(hovered ? 0.5 : 0.25), lineWidth: 0.8)
                    )
                    .shadow(color: SoftPill.CTA.from.opacity(hovered ? 0.55 : 0.35),
                            radius: hovered ? 14 : 8, y: hovered ? 6 : 3)
            )
            .scaleEffect(pressed ? 0.96 : (hovered ? 1.03 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.14), value: hovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: pressed)
    }
}

private struct GhostPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(SoftPill.Text.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(SoftPill.Text.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Editorial permission layout

private struct EditorialPermissionView: View {
    let eyebrow: String
    let headlineTop: String
    let headlineBottom: String
    let accent: Color
    let ctaLabel: String
    let ctaIcon: String?
    let ctaAction: () -> Void
    let secondary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Eyebrow
            HStack(spacing: 6) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 14, height: 1.5)
                Text(eyebrow)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(SoftPill.Text.secondary)
                Spacer()
                Text("APPLE CALENDAR")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(SoftPill.Text.muted)
            }

            // Serif headline — two lines, italic accent on bottom line
            VStack(alignment: .leading, spacing: -2) {
                Text(headlineTop)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(SoftPill.Text.primary)
                Text(headlineBottom)
                    .font(.system(size: 22, design: .serif).italic())
                    .foregroundStyle(
                        LinearGradient(
                            colors: [SoftPill.CTA.from, SoftPill.CTA.to],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }
            .padding(.top, 1)

            // Mini week strip
            WeekStrip(reference: Date(), accent: accent)
                .padding(.top, 2)

            // CTA row
            HStack(spacing: 6) {
                GradientPillButton(label: ctaLabel, icon: ctaIcon, action: ctaAction)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 9))
                        .foregroundStyle(SoftPill.Text.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WeekStrip: View {
    let reference: Date
    let accent: Color

    private var days: [Date] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: reference) // Sun=1
        // Anchor strip to Monday
        let offsetToMonday = ((weekday + 5) % 7)
        guard let monday = cal.date(byAdding: .day, value: -offsetToMonday,
                                    to: cal.startOfDay(for: reference)) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDate(day, inSameDayAs: today)
                DayCell(date: day, isToday: isToday, accent: accent)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private struct DayCell: View {
        let date: Date
        let isToday: Bool
        let accent: Color

        var body: some View {
            VStack(spacing: 2) {
                Text(letter)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(isToday ? .white.opacity(0.95) : SoftPill.Text.muted)
                Text(day)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isToday ? .white : SoftPill.Text.secondary)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    if isToday {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.95), accent.opacity(0.7)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .shadow(color: accent.opacity(0.5), radius: 5, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(SoftPill.Border.subtle,
                                          style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                    }
                }
            )
        }

        private var letter: String {
            let f = DateFormatter(); f.dateFormat = "EEEEE"
            return f.string(from: date).uppercased()
        }
        private var day: String {
            let f = DateFormatter(); f.dateFormat = "d"
            return f.string(from: date)
        }
    }
}

// MARK: - Helpers

private func shortDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    let rem = m % 60
    if rem == 0 { return "\(h)h" }
    return "\(h)h \(rem)m"
}

private func dayLabel(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInTomorrow(date) { return "Tomorrow" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                  to: cal.startOfDay(for: date)).day ?? 0
    if days < 7 {
        let f = DateFormatter(); f.dateFormat = "EEE"
        let weekday = f.string(from: date)
        let t = DateFormatter(); t.timeStyle = .short
        return "\(weekday) \(t.string(from: date))"
    }
    let f = DateFormatter(); f.dateFormat = "MMM d"
    return f.string(from: date)
}
