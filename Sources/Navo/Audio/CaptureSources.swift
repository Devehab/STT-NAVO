import AVFoundation
import CoreAudio
import Foundation

/// A live audio source that delivers 16 kHz mono Float32 samples on its own queue.
/// The callbacks are Sendable: they run on audio threads, never on the main actor.
protocol SampleSource: AnyObject {
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    /// Something went wrong after start (for example the device went away and could not be reopened).
    var onFailure: (@Sendable (String) -> Void)? { get set }
    /// The source reopened after a device change and lost the audio in between.
    var onRestart: (@Sendable () -> Void)? { get set }
    func start() throws
    func stop()
}

enum CaptureError: LocalizedError {
    case noMicrophone
    case microphone(String)
    case systemAudioUnavailable
    case systemAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone found"
        case .microphone(let message):
            return "Could not start the microphone: \(message)"
        case .systemAudioUnavailable:
            return "Recording the Mac's sound needs macOS 14.4 or later"
        case .systemAudio(let step, let status):
            return "Could not record the Mac's sound (\(step), error \(status))"
        }
    }
}

// MARK: Microphone

/// The default microphone through AVAudioEngine. Restarts itself when the input device changes
/// (for example when AirPods connect), so a long recording keeps going.
final class MicCapture: SampleSource {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var onRestart: (@Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var running = false

    func start() throws {
        running = true
        try startEngine()
    }

    func stop() {
        running = false
        stopEngine()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        guard let converter = AVAudioConverter(from: format, to: SpeechAudio.format) else {
            throw CaptureError.microphone("unsupported format")
        }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let samples = SpeechAudio.convert(buffer, with: converter)
            guard let self, !samples.isEmpty else { return }
            self.onSamples?(samples)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.microphone(error.localizedDescription)
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    private func stopEngine() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func restart() {
        guard running else { return }
        stopEngine()
        do {
            try startEngine()
            onRestart?()
        } catch {
            onFailure?(error.localizedDescription)
        }
    }
}

// MARK: System audio

/// Everything the Mac plays (a Google Meet call in Chrome, Zoom, a video) through a Core Audio
/// process tap. Needs macOS 14.4+ and the "System Audio Recording Only" permission, which macOS
/// asks for the first time. When the output device changes, the tap is rebuilt on the new one.
@available(macOS 14.4, *)
final class SystemAudioCapture: SampleSource {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var onRestart: (@Sendable () -> Void)?

    private let controlQueue = DispatchQueue(label: "navo.system-audio.control")
    private let ioQueue = DispatchQueue(label: "navo.system-audio.io", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    private var running = false

    private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func start() throws {
        var failure: Error?
        controlQueue.sync {
            do {
                try build()
                running = true
                watchOutputDevice()
            } catch {
                teardown()
                failure = error
            }
        }
        if let failure { throw failure }
    }

    func stop() {
        controlQueue.sync {
            running = false
            unwatchOutputDevice()
            teardown()
        }
    }

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CaptureError.systemAudio("creating the tap", status) }
        tapID = tap

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &streamDescription)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.systemAudio("reading the tap format", status)
        }
        guard let converter = AVAudioConverter(from: tapFormat, to: SpeechAudio.format) else {
            throw CaptureError.systemAudio("preparing the converter", -1)
        }
        converter.downmix = true

        let outputUID = try Self.defaultOutputUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Navo system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { throw CaptureError.systemAudio("creating the capture device", status) }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self, let buffer = Self.tapBuffer(from: inputData, format: tapFormat) else { return }
            let samples = SpeechAudio.convert(buffer, with: converter)
            if !samples.isEmpty {
                self.onSamples?(samples)
            }
        }
        guard status == noErr, let proc else { throw CaptureError.systemAudio("starting the capture", status) }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw CaptureError.systemAudio("starting the capture", status) }
    }

    /// The tap's audio from the capture device's input. When the output device also has a
    /// microphone (AirPods, a USB headset), its input streams come first and the tap's last,
    /// so the tap's buffers are taken from the end of the list and copied out.
    private static func tapBuffer(from inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let needed = format.isInterleaved ? 1 : Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard needed > 0, bytesPerFrame > 0, list.count >= needed else { return nil }
        let tail = Array(list.suffix(needed))
        let frames = Int(tail[0].mDataByteSize) / bytesPerFrame
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        copy.frameLength = AVAudioFrameCount(frames)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (index, source) in tail.enumerated() where index < target.count {
            guard let from = source.mData, let to = target[index].mData else { continue }
            memcpy(to, from, min(Int(source.mDataByteSize), frames * bytesPerFrame))
        }
        return copy
    }

    private func teardown() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Headphones plugged in or AirPods connected: rebuild the capture on the new output device.
    private func watchOutputDevice() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.teardown()
            do {
                try self.build()
                self.onRestart?()
            } catch {
                self.teardown()
                self.onFailure?(error.localizedDescription)
            }
        }
        listener = block
        var address = Self.defaultOutputAddress()
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
    }

    private func unwatchOutputDevice() {
        guard let listener else { return }
        var address = Self.defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        self.listener = nil
    }

    private static func defaultOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputAddress()
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.systemAudio("finding the output device", status)
        }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw CaptureError.systemAudio("reading the output device", status)
        }
        return value as String
    }
}

enum SystemAudio {
    /// A new capture of everything the Mac plays, or nil before macOS 14.4.
    static func makeCapture() -> SampleSource? {
        if #available(macOS 14.4, *) {
            return SystemAudioCapture()
        }
        return nil
    }
}
