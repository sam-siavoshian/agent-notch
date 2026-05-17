import EventKit
import Foundation

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var todayEvents: [EKEvent] = []
    @Published var upcomingEvents: [EKEvent] = []

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    private init() {
        if authorizationStatus == .fullAccess {
            refresh()
            startTimer()
        }
    }

    func requestAccess() async {
        try? await store.requestFullAccessToEvents()
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .fullAccess {
            refresh()
            startTimer()
        }
    }

    func refresh() {
        let cal = Calendar.current
        let now = Date()

        let todayStart = cal.startOfDay(for: now)
        guard let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart),
              let weekEnd = cal.date(byAdding: .day, value: 8, to: todayStart) else { return }

        let todayPredicate = store.predicateForEvents(withStart: todayStart, end: todayEnd, calendars: nil)
        todayEvents = store.events(matching: todayPredicate)
            .sorted { $0.startDate < $1.startDate }

        let upcomingPredicate = store.predicateForEvents(withStart: todayEnd, end: weekEnd, calendars: nil)
        upcomingEvents = store.events(matching: upcomingPredicate)
            .sorted { $0.startDate < $1.startDate }
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
