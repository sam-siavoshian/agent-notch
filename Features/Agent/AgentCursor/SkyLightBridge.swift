//
//  SkyLightBridge.swift
//  Agent in the Notch
//
//  Private SkyLight SPI for posting mouse events to a target process WITHOUT
//  moving the global cursor. Same pattern yabai uses for focus-without-raise.
//
//  Resolved at runtime via dlsym so the binary still links cleanly if Apple
//  renames or drops the symbol. Returns false on resolution failure; the
//  caller (AgentCursorDriver) falls back to CGEvent.postToPid, which works
//  for native AppKit + most browsers (web content the obvious exception)
//  without the cursor warp side-effect.
//
//  Gated by `AgentSettingsStore.allowPrivateSkyLight` (default true).
//

import Foundation
import CoreGraphics
import ApplicationServices

enum SkyLightBridge {

    // MARK: - SPI resolution

    // Use the public ProcessSerialNumber type from CoreServices (re-exported
    // by ApplicationServices). Wrapping it in our own @convention(c)
    // typealias requires a C-representable signature, which the bridged
    // struct already is.

    private typealias SLPSPostEventRecordToFn = @convention(c) (
        UnsafeMutableRawPointer,        // ProcessSerialNumber*
        UnsafeMutableRawPointer         // event record bytes
    ) -> Int32

    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t,
        UnsafeMutableRawPointer         // ProcessSerialNumber*
    ) -> OSStatus

    private static let skyLightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    private static let coreServicesHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
    }()

    private static let _SLPSPostEventRecordTo: SLPSPostEventRecordToFn? = {
        guard let handle = skyLightHandle,
              let sym = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: SLPSPostEventRecordToFn.self)
    }()

    private static let _GetProcessForPID: GetProcessForPIDFn? = {
        guard let handle = coreServicesHandle,
              let sym = dlsym(handle, "GetProcessForPID") else { return nil }
        return unsafeBitCast(sym, to: GetProcessForPIDFn.self)
    }()

    /// True when the SkyLight bridge is available at runtime AND the user
    /// has not disabled it in settings. AgentCursorDriver reads this before
    /// every Tier-3 dispatch attempt.
    @MainActor
    static var isAvailable: Bool {
        guard AgentSettingsStore.shared.allowPrivateSkyLight else { return false }
        return _SLPSPostEventRecordTo != nil && _GetProcessForPID != nil
    }

    // MARK: - Public dispatch

    /// Best-effort delivery of a CGEvent to `pid` without moving the visible
    /// cursor. Returns true on success, false on any failure — caller is
    /// expected to fall through to CGEvent.postToPid on false.
    static func deliver(_ event: CGEvent, toPID pid: pid_t) -> Bool {
        guard let post = _SLPSPostEventRecordTo,
              let getProcessForPID = _GetProcessForPID else { return false }

        // ProcessSerialNumber is two UInt32 (8 bytes). Allocate raw so we can
        // pass an opaque pointer compatible with the @convention(c) typealias
        // without naming the type at the call boundary.
        let psnSize = MemoryLayout<UInt64>.size
        let psnBuf = UnsafeMutableRawPointer.allocate(byteCount: psnSize, alignment: 8)
        defer { psnBuf.deallocate() }
        psnBuf.initializeMemory(as: UInt8.self, repeating: 0, count: psnSize)

        let err = getProcessForPID(pid, psnBuf)
        guard err == noErr else { return false }

        // SkyLight event record buffer. The first slot holds the CGEvent
        // opaque pointer; SkyLight reads the event's private state via that
        // reference. yabai/process_manager.c uses the same layout.
        let recordSize = 0xF8
        let recordBuf = UnsafeMutableRawPointer.allocate(byteCount: recordSize, alignment: 8)
        defer { recordBuf.deallocate() }
        recordBuf.initializeMemory(as: UInt8.self, repeating: 0, count: recordSize)

        let cgRef = Unmanaged.passUnretained(event).toOpaque()
        recordBuf.storeBytes(of: cgRef, as: UnsafeMutableRawPointer.self)

        let result = post(psnBuf, recordBuf)
        return result == 0
    }
}
