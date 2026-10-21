import CoreMIDI
import Foundation

/// Listens to every connected MIDI source. Control-change values become modulation
/// sources; notes can trigger envelopes and switch scenes.
final class MIDIManager {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let lock = NSLock()
    private var ccValues: [Int: Float] = [:]
    private var pendingNotes: [(channel: Int, note: Int)] = []
    private var lastCC: (channel: Int, cc: Int)?

    init() {
        MIDIClientCreateWithBlock("Lightmapping" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged { self?.connectAllSources() }
        }
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { [weak self] eventList, _ in
            self?.handle(eventList)
        }
        connectAllSources()
    }

    func connectAllSources() {
        for i in 0..<MIDIGetNumberOfSources() {
            MIDIPortConnectSource(port, MIDIGetSource(i), nil)
        }
    }

    var sourceNames: [String] {
        (0..<MIDIGetNumberOfSources()).map { i in
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &name)
            return (name?.takeRetainedValue() as String?) ?? "MIDI source \(i + 1)"
        }
    }

    var cc: [Int: Float] {
        lock.lock(); defer { lock.unlock() }
        return ccValues
    }

    /// Notes received since the last call.
    func drainNotes() -> [(channel: Int, note: Int)] {
        lock.lock(); defer { lock.unlock() }
        let n = pendingNotes
        pendingNotes.removeAll()
        return n
    }

    /// Most recent CC (for MIDI learn), cleared on read.
    func takeLastCC() -> (channel: Int, cc: Int)? {
        lock.lock(); defer { lock.unlock() }
        let v = lastCC
        lastCC = nil
        return v
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words: [UInt32] = withUnsafeBytes(of: packet.pointee.words) { raw in
                Array(raw.bindMemory(to: UInt32.self).prefix(count))
            }
            for word in words {
                // Universal MIDI Packet, message type 2 = MIDI 1.0 channel voice.
                guard word >> 28 == 0x2 else { continue }
                let status = Int((word >> 16) & 0xF0)
                let channel = Int((word >> 16) & 0x0F)
                let d1 = Int((word >> 8) & 0x7F)
                let d2 = Int(word & 0x7F)
                lock.lock()
                switch status {
                case 0xB0:
                    ccValues[channel * 128 + d1] = Float(d2) / 127
                    lastCC = (channel, d1)
                case 0x90 where d2 > 0:
                    pendingNotes.append((channel, d1))
                default:
                    break
                }
                lock.unlock()
            }
        }
    }
}
