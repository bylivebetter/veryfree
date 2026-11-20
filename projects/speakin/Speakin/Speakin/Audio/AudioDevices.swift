//
//  AudioDevices.swift
//  Speakin
//
//  Read-only questions about the audio hardware: what is plugged in, what each device delivers, and —
//  the one that matters on a call — which microphone other apps are capturing from right now, so a
//  recording hears the user through the same mic the call does.
//

import CoreAudio
import Foundation

nonisolated struct AudioDevice: Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Hardware — not an aggregate (ours or another app's) and not a virtual loopback like Teams' or
    /// BlackHole, which carry app audio rather than a voice.
    var isPhysical: Bool {
        transport != kAudioDeviceTransportTypeAggregate
            && transport != kAudioDeviceTransportTypeAutoAggregate
            && transport != kAudioDeviceTransportTypeVirtual
    }
}

nonisolated enum AudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Property access

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ type: T.Type,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    /// CoreAudio hands strings over retained; taking them that way keeps repeated polling from leaking.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    // MARK: - Devices

    static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard id != AudioObjectID(kAudioObjectUnknown), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                           transport: scalar(id, kAudioDevicePropertyTransportType, UInt32.self) ?? 0)
    }

    static func device(uid: String) -> AudioDevice? {
        allDevices().first { $0.uid == uid }
    }

    static func allDevices() -> [AudioDevice] {
        objects(system, kAudioHardwarePropertyDevices).compactMap(device)
    }

    static var defaultInput: AudioObjectID? { known(scalar(system, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID.self)) }
    static var defaultOutput: AudioObjectID? { known(scalar(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID.self)) }

    private static func known(_ id: AudioObjectID?) -> AudioObjectID? {
        guard let id, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// False once the device is unplugged, disconnected or otherwise gone.
    static func isAlive(_ id: AudioObjectID) -> Bool {
        scalar(id, kAudioDevicePropertyDeviceIsAlive, UInt32.self) == 1
    }

    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32.self) == 1
    }

    static func sampleRate(_ id: AudioObjectID) -> Double? {
        guard let rate = scalar(id, kAudioDevicePropertyNominalSampleRate, Float64.self), rate > 0 else { return nil }
        return rate
    }

    /// Channels of each stream in a scope, in the order an IOProc receives the buffers.
    static func streamChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    static func hasInput(_ id: AudioObjectID) -> Bool { !streamChannels(id, scope: kAudioObjectPropertyScopeInput).isEmpty }
    static func hasOutput(_ id: AudioObjectID) -> Bool { !streamChannels(id, scope: kAudioObjectPropertyScopeOutput).isEmpty }

    // MARK: - Choosing devices

    /// The device whose clock paces system-audio capture. The built-in output wins when there is one: it
    /// does not come and go like headphones, and never drops into a call mode like a Bluetooth headset,
    /// so changing what you listen on does not disturb the recording.
    static func clockDevice() -> AudioDevice? {
        let outputs = allDevices().filter { $0.isPhysical && isAlive($0.id) && hasOutput($0.id) }
        return outputs.first { $0.isBuiltIn && !hasInput($0.id) }
            ?? defaultOutput.flatMap { id in outputs.first { $0.id == id } }
            ?? outputs.first { !hasInput($0.id) }
            ?? outputs.first
    }

    /// Real microphones, for choosing one by hand.
    static func microphones() -> [AudioDevice] {
        allDevices().filter { $0.isPhysical && hasInput($0.id) }
    }

    /// Apps people take calls in. When several microphones are busy, theirs is the one to record.
    private static let callAppPrefixes = [
        "us.zoom.", "com.microsoft.teams", "com.google.Chrome", "com.apple.FaceTime", "com.apple.WebKit",
        "com.apple.Safari", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.cisco.webex", "Cisco-Systems.Spark",
        "net.whatsapp.", "com.microsoft.edgemac", "company.thebrowser.", "com.brave.Browser", "org.mozilla.firefox",
    ]

    /// The microphone a call — or any other app — is capturing from right now, if it can be seen.
    /// Preference: the app being recorded, then call apps, then anyone; within each, a headset over the
    /// built-in mic (if both are busy, the headset is the one being talked into), then the default input.
    static func microphoneInUse(preferring bundleID: String?) -> AudioObjectID? {
        let ownPID = getpid()
        var ownDevices = Set<AudioObjectID>()
        var byTier: [[AudioObjectID]] = [[], [], []]
        for process in objects(system, kAudioHardwarePropertyProcessObjectList) {
            let devices = objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            guard !devices.isEmpty else { continue }
            if scalar(process, kAudioProcessPropertyPID, pid_t.self) == ownPID {
                ownDevices.formUnion(devices)
                continue
            }
            guard scalar(process, kAudioProcessPropertyIsRunningInput, UInt32.self) == 1 else { continue }
            let processBundleID = string(process, kAudioProcessPropertyBundleID) ?? ""
            let tier = processBundleID == bundleID ? 0 : callAppPrefixes.contains { processBundleID.hasPrefix($0) } ? 1 : 2
            byTier[tier] += devices.flatMap { microphones(behind: $0) }
        }
        for candidates in byTier {
            if let pick = best(of: candidates) { return pick }
        }
        // Apps that use voice processing capture through a private device nobody else can see into; the
        // microphone underneath still shows as running. (Input-only devices: a headset that is also
        // playing would show as running without anyone using its mic.)
        let running = microphones().map(\.id).filter {
            !ownDevices.contains($0) && !hasOutput($0) && isRunningSomewhere($0)
        }
        return best(of: running)
    }

    /// The default input — unless it is a Bluetooth headset nobody is using. Opening its mic would drop
    /// the user's listening to call quality just for us, so the built-in mic stands in until a call
    /// actually uses the headset (and `microphoneInUse` then finds it).
    static func idleSafeDefaultInput() -> AudioObjectID? {
        guard let id = defaultInput, let device = device(id),
              device.transport == kAudioDeviceTransportTypeBluetooth || device.transport == kAudioDeviceTransportTypeBluetoothLE,
              !isRunningSomewhere(id) else { return defaultInput }
        return microphones().first { $0.isBuiltIn }?.id ?? id
    }

    /// The physical microphones a device stands for: itself, or the members of an aggregate.
    private static func microphones(behind id: AudioObjectID, depth: Int = 0) -> [AudioObjectID] {
        // Another app's private device is invisible to us; nothing to learn from it.
        guard depth < 3, let device = device(id) else { return [] }
        if device.transport == kAudioDeviceTransportTypeAggregate || device.transport == kAudioDeviceTransportTypeAutoAggregate {
            return objects(id, kAudioAggregateDevicePropertyActiveSubDeviceList).flatMap { microphones(behind: $0, depth: depth + 1) }
        }
        return device.isPhysical && hasInput(id) ? [id] : []
    }

    private static func best(of candidates: [AudioObjectID]) -> AudioObjectID? {
        guard !candidates.isEmpty else { return nil }
        if let headset = candidates.first(where: { device($0)?.isBuiltIn == false }) { return headset }
        if let defaultInput, candidates.contains(defaultInput) { return defaultInput }
        return candidates.first
    }
}
