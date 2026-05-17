import EventKit
import SwiftUI

struct NotchCalendarView: View {
    @ObservedObject private var service = CalendarService.shared

    var body: some View {
        switch service.authorizationStatus {
        case .fullAccess:
            authorizedView
        case .denied, .restricted:
            deniedView
        default:
            requestView
        }
    }

    // MARK: - Request access state

    private var requestView: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.red.opacity(0.85))

            VStack(spacing: 3) {
                Text("Apple Calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.primary)
                Text("See today's events in your notch.")
                    .font(.system(size: 10))
                    .foregroundStyle(SoftPill.Text.secondary)
                    .multilineTextAlignment(.center)
            }

            CalendarAccessButton(label: "Allow Access") {
                Task { await service.requestAccess() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - Denied state

    private var deniedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(SoftPill.Status.amber)

            VStack(spacing: 3) {
                Text("Calendar Access Denied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.primary)
                Text("Enable in System Settings to see your events.")
                    .font(.system(size: 10))
                    .foregroundStyle(SoftPill.Text.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(GhostPillButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - Authorized state

    @ViewBuilder
    private var authorizedView: some View {
        if service.todayEvents.isEmpty && service.upcomingEvents.isEmpty {
            emptyView
        } else {
            eventsView
        }
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(SoftPill.Status.green)
            Text("You're free!")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SoftPill.Text.primary)
            Text("No events today")
                .font(.system(size: 10))
                .foregroundStyle(SoftPill.Text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var eventsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(todayHeader)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SoftPill.Text.secondary)
                .padding(.horizontal, 2)

            if service.todayEvents.isEmpty {
                Text("No events today")
                    .font(.system(size: 10))
                    .foregroundStyle(SoftPill.Text.muted)
                    .padding(.horizontal, 2)
            } else {
                ForEach(service.todayEvents, id: \.eventIdentifier) { event in
                    CalendarEventRow(event: event)
                }
            }

            if !service.upcomingEvents.isEmpty {
                HStack {
                    Rectangle()
                        .fill(SoftPill.Border.subtle)
                        .frame(height: 0.5)
                    Text("UPCOMING")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.muted)
                    Rectangle()
                        .fill(SoftPill.Border.subtle)
                        .frame(height: 0.5)
                }
                .padding(.top, 2)

                ForEach(service.upcomingEvents.prefix(5), id: \.eventIdentifier) { event in
                    CalendarEventRow(event: event, showDate: true)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    private var todayHeader: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }
}

// MARK: - Event row

private struct CalendarEventRow: View {
    let event: EKEvent
    var showDate: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(calendarColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.primary)
                    .lineLimit(1)

                Text(timeLabel)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(SoftPill.Text.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SoftPill.Surface.raised)
        )
    }

    private var calendarColor: Color {
        if let cgColor = event.calendar?.cgColor {
            return Color(cgColor: cgColor)
        }
        return SoftPill.Status.blue
    }

    private var timeLabel: String {
        if event.isAllDay {
            return showDate ? dateOnly : "All Day"
        }
        if showDate {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f.string(from: event.startDate)
        }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: event.startDate)
    }

    private var dateOnly: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: event.startDate)
    }
}

// MARK: - Buttons

private struct CalendarAccessButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SoftPill.CTA.from, SoftPill.CTA.to],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .scaleEffect(isHovered ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
