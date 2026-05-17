//
//  AudioDeviceManager.swift
//  Agent in the Notch
//
//  Lists CoreAudio input/output devices and exposes helpers to bind
//  AVAudioEngine input/output to a user-selected device by UID.
//  Reacts to device hot-plug events via kAudioHardwarePropertyDevices.
//

import AVFoundation
import CoreAudio
import Foundation
import Combine

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
}

@MainActor
public final class AudioDeviceManager: ObservableObject {
    public static let shared = AudioDeviceManager()

    @Published public private(set) var inputs: [AudioDevice] = []
    @Published public private(set) var outputs: [AudioDevice] = []

    private var listenerAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        refresh()
        installListener()
    }

    deinit {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &listenerAddr,
                DispatchQueue.main,
                block
            )
        }
    }

    public func refresh() {
        let all = Self.enumerateAllDevices()
        inputs = all.filter { $0.hasInput }
        outputs = all.filter { $0.hasOutput }
    }

    public func input(forUID uid: String?) -> AudioDevice? {
        guard let uid, !uid.isEmpty else { return nil }
        return inputs.first { $0.uid == uid }
    }

    public func output(forUID uid: String?) -> AudioDevice? {
        guard let uid, !uid.isEmpty else { return nil }
        return outputs.first { $0.uid == uid }
    }

    /// Apply selected device UID to an AVAudioEngine's input audio unit.
    /// Pass nil to fall back to system default. Returns true if applied.
    @discardableResult
    public static func setInputDevice(uid: String?, on engine: AVAudioEngine) -> Bool {
        guard let uid, !uid.isEmpty,
              let device = enumerateAllDevices().first(where: { $0.uid == uid && $0.hasInput })
        else { return false }
        guard let unit = engine.inputNode.audioUnit else { return false }
        var deviceID = device.id
        let err = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return err == noErr
    }

    /// Apply selected device UID to an AVAudioEngine's output audio unit.
    @discardableResult
    public static func setOutputDevice(uid: String?, on engine: AVAudioEngine) -> Bool {
        guard let uid, !uid.isEmpty,
              let device = enumerateAllDevices().first(where: { $0.uid == uid && $0.hasOutput })
        else { return false }
        guard let unit = engine.outputNode.audioUnit else { return false }
        var deviceID = device.id
        let err = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return err == noErr
    }

    // MARK: - CoreAudio enumeration

    private func installListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listenerAddr,
            DispatchQueue.main,
            block
        )
    }

    fileprivate static func enumerateAllDevices() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap(deviceInfo)
    }

    private static func deviceInfo(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID,
                                       scope: kAudioObjectPropertyScopeGlobal) else { return nil }
        let name = stringProperty(id, selector: kAudioObjectPropertyName,
                                  scope: kAudioObjectPropertyScopeGlobal) ?? uid
        let hasInput  = channelCount(id, scope: kAudioObjectPropertyScopeInput)  > 0
        let hasOutput = channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        guard hasInput || hasOutput else { return nil }
        return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput)
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let err = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let s = cf as String? else { return nil }
        return s
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
