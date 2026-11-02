import AudioToolbox
import CoreAudio
import Foundation

/// The sound of every app but Nuri (Core Audio process tap, macOS 14.2+), for screen sharing.
/// Nuri's web processes play the call's voices: they are left out, also when one starts after
/// the tap (WebKit launches them as needed). macOS asks once for the permission
/// (NSAudioCaptureUsageDescription); refused, the tap only hears silence, which isn't sent.
@available(macOS 14.2, *)
final class SystemAudioTap {
    /// 16-bit stereo PCM in base64, and its sample rate. Called on the tap's queue, every ~50 ms
    /// of sound (silence isn't sent).
    typealias Output = (String, Double) -> Void

    private let output: Output
    private let queue = DispatchQueue(label: "app.nuri.share-audio", qos: .userInteractive)
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var format = AudioStreamBasicDescription()
    private var pending: [Int16] = []
    private var pendingHeard = false
    /// Read and written on the queue.
    private var stopped = false
    private var tornDown = false

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init?(output: @escaping Output) {
        self.output = output
        description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.nuriProcesses())
        description.uuid = UUID()
        description.name = "Nuri — son partagé"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard start() else {
            stop()
            return nil
        }
    }

    private func start() -> Bool {
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0,
              let outputUID = Self.defaultOutputUID() else { return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nuri — son partagé",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else { return false }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else { return false }
        // Web processes started later (WebKit launches them as needed) are left out too.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateExclusions() }
        var listAddress = Self.processListAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddress, queue, listener) == noErr {
            processListener = listener
        }
        return true
    }

    /// Safe to call more than once.
    func stop() {
        guard !tornDown else { return }
        queue.sync { stopped = true }
        tearDown()
    }

    /// Without waiting for the queue: the last reference may go while a buffer is handled on it.
    deinit {
        stopped = true
        tearDown()
    }

    private func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        if let processListener {
            var listAddress = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddress, queue, processListener)
        }
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    // MARK: Sound

    /// On the queue: float samples to 16-bit interleaved stereo, sent by ~50 ms.
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard !stopped else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(max(1, format.mChannelsPerFrame))
        func samples(_ buffer: AudioBuffer) -> UnsafeBufferPointer<Float32> {
            UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Float32.self),
                                count: Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size)
        }
        func append(_ left: Float32, _ right: Float32) {
            if left != 0 || right != 0 { pendingHeard = true }
            pending.append(Int16(max(-1, min(1, left)) * 32767))
            pending.append(Int16(max(-1, min(1, right)) * 32767))
        }
        if interleaved, let buffer = buffers.first {
            let all = samples(buffer)
            let step = Int(max(1, buffer.mNumberChannels))
            for i in stride(from: 0, to: all.count - step + 1, by: step) {
                append(all[i], all[i + (step > 1 ? 1 : 0)])
            }
        } else if !buffers.isEmpty {
            let left = samples(buffers[0])
            let right = buffers.count > 1 && channels > 1 ? samples(buffers[1]) : left
            for i in 0..<min(left.count, right.count) { append(left[i], right[i]) }
        }
        guard pending.count >= Int(format.mSampleRate * 0.05) * 2 else { return }
        if pendingHeard {
            let data = pending.withUnsafeBufferPointer { Data(buffer: $0) }
            output(data.base64EncodedString(), format.mSampleRate)
        }
        pending.removeAll(keepingCapacity: true)
        pendingHeard = false
    }

    // MARK: Processes

    private func updateExclusions() {
        guard !stopped, tapID != kAudioObjectUnknown else { return }
        let processes = Self.nuriProcesses()
        guard Set(processes) != Set(description.processes) else { return }
        description.processes = processes
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CATapDescription = description
        _ = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
    }

    /// Core Audio's objects for Nuri and the WebKit processes working for it (their "responsible"
    /// process is Nuri: that's how macOS attributes their camera or sound to it).
    private static func nuriProcesses() -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = getpid()
        return objects.filter { object in
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return false }
            return pid == me || responsiblePID(pid) == me
        }
    }

    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? { responsibleFunction?(pid) }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
