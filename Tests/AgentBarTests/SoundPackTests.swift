import AVFoundation
import Foundation
import Testing
@testable import AgentBar

/// Your own sounds. What is tested is the choosing — a directory listing in, a
/// file per cue out — and the two ceilings, because a folder is where people drop
/// whatever they have and a ten-minute song must never become the "done" cue.
@Suite struct SoundPackTests {
    private typealias Entry = SoundPack.Entry
    private let small = 40_000

    @Test func eachCueIsFoundUnderItsOwnName() {
        let got = SoundPack.resolve([Entry(name: "permission.aiff", size: small),
                                     Entry(name: "question.wav", size: small),
                                     Entry(name: "done.mp3", size: small),
                                     Entry(name: "ack.caf", size: small)])
        #expect(got[.permission] == .file(Entry(name: "permission.aiff", size: small)))
        #expect(got[.question] == .file(Entry(name: "question.wav", size: small)))
        #expect(got[.done] == .file(Entry(name: "done.mp3", size: small)))
        #expect(got[.ack] == .file(Entry(name: "ack.caf", size: small)))
    }

    /// The names are a contract somebody's folder depends on.
    @Test func theNamesAreTheCuesRawValues() {
        #expect(SoundCenter.Cue.allCases.map(\.rawValue) == ["permission", "question", "done", "ack"])
    }

    @Test func anEmptyOrMissingFolderMeansEveryCueIsAgentBars() {
        #expect(SoundPack.resolve([]).isEmpty)
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-no-sounds-\(UUID().uuidString)")
        #expect(SoundPack.listing(of: nowhere).isEmpty)
    }

    @Test func caseDoesNotMatter() {
        #expect(SoundPack.resolve([Entry(name: "Done.WAV", size: small)])[.done]
                == .file(Entry(name: "Done.WAV", size: small)))
    }

    @Test func anythingElseInTheFolderIsIgnored() {
        let got = SoundPack.resolve([Entry(name: "done.ogg", size: small),
                                     Entry(name: "done", size: small),
                                     Entry(name: ".done.wav", size: small),
                                     Entry(name: "done.wav.txt", size: small),
                                     Entry(name: "finished.wav", size: small),
                                     Entry(name: "README.md", size: small),
                                     Entry(name: "done copy.wav", size: small)])
        #expect(got.isEmpty)
    }

    /// Several files for one cue: uncompressed first, in the documented order.
    @Test func moreThanOneFileForACuePicksByExtensionOrder() {
        let got = SoundPack.resolve([Entry(name: "done.m4a", size: small),
                                     Entry(name: "done.wav", size: small),
                                     Entry(name: "done.mp3", size: small)])
        #expect(got[.done] == .file(Entry(name: "done.wav", size: small)))
    }

    @Test func aFileOverTheSizeCeilingIsNeverChosen() {
        let big = SoundPack.maxBytes + 1
        #expect(SoundPack.resolve([Entry(name: "done.mp3", size: 60_000_000)])[.done]
                == .refused(Entry(name: "done.mp3", size: 60_000_000), .tooLarge))
        // …but a smaller file for the same cue still is.
        #expect(SoundPack.resolve([Entry(name: "done.aiff", size: big),
                                   Entry(name: "done.m4a", size: small)])[.done]
                == .file(Entry(name: "done.m4a", size: small)))
        #expect(SoundPack.resolve([Entry(name: "done.wav", size: SoundPack.maxBytes)])[.done]
                == .file(Entry(name: "done.wav", size: SoundPack.maxBytes)))
    }

    // MARK: - Duration, from a real file

    private func wav(seconds: Double, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-cue-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: channels))
        let frames = AVAudioFrameCount(8_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = sin(Float(i) * 0.3) * 0.2 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func aShortFileLoadsWithTheLeadInInFront() throws {
        let url = try wav(seconds: 0.5, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SoundPack.probe(url) == nil)
        let buffer = try SoundPack.load(url).get()
        #expect(buffer.format.channelCount == 2)
        #expect(buffer.frameLength == 4_000 + 80)  // 0.5 s + 10 ms at 8 kHz
        #expect(buffer.floatChannelData![0][0] == 0)
    }

    /// The whole point of the second ceiling: small enough to pass the size check,
    /// far too long to be a cue.
    @Test func aFileLongerThanTheCeilingIsNotPlayed() throws {
        let url = try wav(seconds: SoundPack.maxSeconds + 1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SoundPack.probe(url) == .tooLong)
        #expect(throws: SoundPack.Refusal.tooLong) { try SoundPack.load(url).get() }
    }

    @Test func somethingThatIsNotASoundIsRefused() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-cue-\(UUID().uuidString).mp3")
        try Data("not audio at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SoundPack.probe(url) == .unreadable)
    }

    // MARK: - What Settings says

    @Test func theLineNamesWhatIsYoursAndWhatWasPassedOver() {
        #expect(SoundPack.summary([], probe: { _ in nil }).hasPrefix("All four are AgentBar's."))
        let line = SoundPack.summary([Entry(name: "done.wav", size: small),
                                      Entry(name: "ack.wav", size: small),
                                      Entry(name: "question.mp3", size: small),
                                      Entry(name: "permission.aiff", size: 9_000_000)],
                                     probe: { $0.name == "question.mp3" ? .tooLong : nil })
        #expect(line.contains("Yours: done and ack."))
        #expect(line.contains("question.mp3 (longer than 3 s)"))
        #expect(line.contains("permission.aiff (over 2 MB)"))
    }
}

