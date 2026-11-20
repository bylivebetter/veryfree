//
//  SessionCapture.swift
//  Speakin
//
//  The two halves of a recorded call, each captured on its own so neither can take the other down:
//  what the Mac plays (a CoreAudio process tap) and the user's microphone (an IOProc straight on the
//  device). Both hand every input buffer to a handler together with the host time it was captured at.
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation

nonisolated enum SessionCaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case noOutputDevice
    case noMicrophone
    case ioProcFailed(OSStatus)
    case appNotPlaying(String)
    case audioSystemNotResponding

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s): "macOS would not start an audio tap (\(s)). Allow Speakin under Privacy & Security → Audio Recording."
        case .aggregateCreationFailed(let s): "Could not build the recording device (\(s))."
        case .noOutputDevice: "No audio output device is available."
        case .noMicrophone: "No microphone is available."
        case .ioProcFailed(let s): "Could not start the recording device (\(s))."
        case .appNotPlaying(let name): "\(name) is not playing any audio right now."
        case .audioSystemNotResponding: "The Mac's audio system did not respond. Try again in a moment."
        }
    }
}

/// One stream of an IOProc's input, and the host time of its first frame (0 if unknown).
typealias CapturedStreamHandler = (AudioBuffer, UInt64) -> Void

/// One IOProc on one device. Start and stop it from a queue other than the one the IOProc runs on:
/// stopping from inside that queue would wait on itself.
nonisolated final class DeviceIOProc: @unchecked Sendable {
    let deviceID: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    /// Calls `handler` with input stream `streamIndex` (the last stream if there are fewer).
    init(deviceID: AudioObjectID, streamIndex: Int, queue: DispatchQueue, handler: @escaping CapturedStreamHandler) throws {
        self.deviceID = deviceID
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count > 0 else { return }
            let stream = buffers[min(streamIndex, buffers.count - 1)]
            let time = inputTime.pointee
            handler(stream, time.mFlags.contains(.hostTimeValid) ? time.mHostTime : 0)
        }
        guard status == noErr, let procID else { throw SessionCaptureError.ioProcFailed(status) }
        let started = AudioDeviceStart(deviceID, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            throw SessionCaptureError.ioProcFailed(started)
        }
        self.procID = procID
    }

    /// Once this returns, the handler is not called again.
    func stop() {
        guard let procID else { return }
        self.procID = nil
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }
}

/// What the Mac is playing: a process tap captures other apps' output on its way to the speakers, so
/// nothing is heard twice and no Screen Recording permission is needed. The tap lives in a private
/// aggregate device whose only job is to give it a steady clock.
nonisolated final class SystemAudioCapture: @unchecked Sendable {
    let source: SystemAudioSource
    let clock: AudioDevice
    let sampleRate: Double
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let tapStreamIndex: Int
    private var io: DeviceIOProc?
    private var destroyed = false

    init(source: SystemAudioSource) throws {
        self.source = source
        let description: CATapDescription
        switch source {
        case .allAudio:
            let excluded = AudioProcessList.ownProcessObject.map { [NSNumber(value: $0)] } ?? []
            description = CATapDescription(__stereoGlobalTapButExcludeProcesses: excluded)
        case .app(let bundleID, let name):
            let objects = AudioProcessList.processObjects(forBundleID: bundleID)
            guard !objects.isEmpty else { throw SessionCaptureError.appNotPlaying(name) }
            description = CATapDescription(__stereoMixdownOfProcesses: objects.map { NSNumber(value: $0) })
            // macOS 26 keeps the tap on this app even if it quits and comes back mid-call.
            description.bundleIDs = [bundleID]
            description.isProcessRestoreEnabled = true
        }
        description.name = "Speakin recording"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted   // the user keeps hearing the call

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw SessionCaptureError.tapCreationFailed(tapStatus)
        }
        guard let tapUID = AudioDevices.string(tapID, kAudioTapPropertyUID), let clock = AudioDevices.clockDevice() else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SessionCaptureError.noOutputDevice
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Speakin Recording",
            kAudioAggregateDeviceUIDKey: "com.bylivebetter.apps.Speakin.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clock.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SessionCaptureError.aggregateCreationFailed(aggregateStatus)
        }

        self.clock = clock
        self.tapID = tapID
        self.aggregateID = aggregateID
        // The tap's stream comes after the clock device's own inputs (normally it has none).
        tapStreamIndex = AudioDevices.streamChannels(clock.id, scope: kAudioObjectPropertyScopeInput).count
        sampleRate = AudioDevices.sampleRate(aggregateID) ?? AudioDevices.sampleRate(clock.id) ?? 48_000
    }

    func start(on queue: DispatchQueue, handler: @escaping CapturedStreamHandler) throws {
        io = try DeviceIOProc(deviceID: aggregateID, streamIndex: tapStreamIndex, queue: queue, handler: handler)
    }

    /// False once the clock device has gone or changed rate; the capture must then be rebuilt.
    var isIntact: Bool {
        AudioDevices.isAlive(clock.id) && AudioDevices.sampleRate(aggregateID) == sampleRate
    }

    func stop() {
        io?.stop()
        io = nil
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// The user's voice: an IOProc straight on one microphone — no aggregate, no output device — so
/// plugging in headphones, or a Bluetooth headset switching into call mode, cannot take it down.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    let device: AudioDevice
    let sampleRate: Double
    private let channels: Int
    private var io: DeviceIOProc?

    init(device: AudioDevice) throws {
        guard let rate = AudioDevices.sampleRate(device.id),
              let channels = AudioDevices.streamChannels(device.id, scope: kAudioObjectPropertyScopeInput).first,
              channels > 0 else {
            throw SessionCaptureError.noMicrophone
        }
        self.device = device
        self.sampleRate = rate
        self.channels = channels
    }

    func start(on queue: DispatchQueue, handler: @escaping CapturedStreamHandler) throws {
        io = try DeviceIOProc(deviceID: device.id, streamIndex: 0, queue: queue, handler: handler)
    }

    /// False once the microphone is gone or delivers a different format (a headset switching modes).
    var isIntact: Bool {
        AudioDevices.isAlive(device.id)
            && AudioDevices.sampleRate(device.id) == sampleRate
            && AudioDevices.streamChannels(device.id, scope: kAudioObjectPropertyScopeInput).first == channels
    }

    func stop() {
        io?.stop()
        io = nil
    }
}
