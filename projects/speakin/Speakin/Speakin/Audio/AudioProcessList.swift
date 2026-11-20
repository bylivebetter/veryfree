//
//  AudioProcessList.swift
//  Speakin
//
//  CoreAudio's view of which processes are playing audio right now, so a recording can be limited
//  to one app ("just Zoom") instead of everything coming out of the Mac.
//

import AppKit
import CoreAudio
import Foundation

nonisolated enum SystemAudioSource: Hashable, Codable, Sendable {
    case allAudio
    case app(bundleID: String, name: String)

    var displayName: String {
        switch self {
        case .allAudio: "All audio"
        case .app(_, let name): name
        }
    }

    var bundleID: String? {
        if case .app(let id, _) = self { return id }
        return nil
    }
}

nonisolated struct AudioProcess: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let isPlaying: Bool

    var id: AudioObjectID { objectID }
}

nonisolated enum AudioProcessList {
    /// Audio object representing a process, for tap include/exclude lists.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var inputPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &inputPID, &size, &objectID)
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    static var ownProcessObject: AudioObjectID? {
        processObject(for: getpid())
    }

    /// Every process CoreAudio knows about, newest-sounding first: currently playing apps, then the rest.
    static func current() -> [AudioProcess] {
        let objects = AudioDevices.objects(AudioDevices.system, kAudioHardwarePropertyProcessObjectList)

        let runningApps = NSWorkspace.shared.runningApplications
        let ownPID = getpid()
        var processes: [AudioProcess] = []
        for object in objects {
            guard let pid = AudioDevices.scalar(object, kAudioProcessPropertyPID, pid_t.self), pid != ownPID else { continue }
            let bundleID = AudioDevices.string(object, kAudioProcessPropertyBundleID) ?? ""
            let app = runningApps.first { $0.processIdentifier == pid }
            // Only apps the user can recognize; faceless audio daemons are noise in a menu.
            guard let name = app?.localizedName ?? (bundleID.isEmpty ? nil : bundleID.components(separatedBy: ".").last) else { continue }
            let playing = (AudioDevices.scalar(object, kAudioProcessPropertyIsRunningOutput, UInt32.self) ?? 0) != 0
            processes.append(AudioProcess(objectID: object, pid: pid, bundleID: bundleID.isEmpty ? (app?.bundleIdentifier ?? "") : bundleID,
                                          name: name, isPlaying: playing))
        }
        // One row per app, preferring an instance that is actually playing.
        var byBundle: [String: AudioProcess] = [:]
        for process in processes {
            let key = process.bundleID.isEmpty ? process.name : process.bundleID
            if let existing = byBundle[key], existing.isPlaying || !process.isPlaying { continue }
            byBundle[key] = process
        }
        return byBundle.values.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Audio objects for every running instance of a bundle ID.
    static func processObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        current().filter { $0.bundleID == bundleID }.map(\.objectID)
    }
}
