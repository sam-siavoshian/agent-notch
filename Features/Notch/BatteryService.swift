//
//  BatteryService.swift
//  Agent in the Notch
//

import Foundation
import IOKit.ps

@MainActor
final class BatteryService: ObservableObject {
    static let shared = BatteryService()

    @Published private(set) var percentage: Int = 100
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var hasBattery: Bool = false

    private init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        guard let rawInfo = IOPSCopyPowerSourcesInfo() else { hasBattery = false; return }
        let info = rawInfo.takeRetainedValue()

        guard let rawList = IOPSCopyPowerSourcesList(info),
              let list = rawList.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else { hasBattery = false; return }

        for source in list {
            guard let rawDesc = IOPSGetPowerSourceDescription(info, source),
                  let desc = rawDesc.takeUnretainedValue() as? [String: AnyObject],
                  (desc[kIOPSTypeKey] as? String) == "InternalBattery"
            else { continue }

            hasBattery  = true
            percentage  = desc[kIOPSCurrentCapacityKey] as? Int  ?? percentage
            isCharging  = desc[kIOPSIsChargingKey]      as? Bool ?? false
            return
        }
        hasBattery = false
    }
}
