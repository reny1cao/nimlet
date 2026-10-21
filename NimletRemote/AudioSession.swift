import Foundation
import AVFoundation

/// One owner for `AVAudioSession`, because there are now two things that want it.
///
/// There used to be one: dictation set the category on the way in and
/// deactivated it on the way out, and nothing else in the app made or took a
/// sound. Listening to the Mac makes that arrangement actively wrong — letting
/// go of a hold-to-talk button would call `setActive(false)` and stop the audio
/// that is playing in your pocket, and the symptom would be "sound stops if I
/// ever dictate", which is a bug nobody would connect to the microphone.
///
/// So the session has an owner, and the two callers say what they want rather
/// than how to get it. The category follows from that: recording wins while it
/// is happening, because a `.playback` session cannot open a microphone;
/// playback holds the session on its own; and it is only deactivated when
/// neither of them wants it, which is what lets whatever the user was playing
/// before come back.
@MainActor
enum AudioSession {

    private static var dictating = false
    private static var listening = false

    /// Dictation is starting. Throws, because a session that will not configure
    /// is the difference between a recording and silence, and the caller shows
    /// the error.
    static func beginDictation() throws {
        let previous = dictating
        dictating = true
        do { try apply() } catch {
            dictating = previous
            try? apply()
            throw error
        }
    }

    static func endDictation() {
        dictating = false
        try? apply()
    }

    /// The Mac's audio is about to play here.
    static func beginListening() throws {
        let previous = listening
        listening = true
        do { try apply() } catch {
            listening = previous
            try? apply()
            throw error
        }
    }

    static func endListening() {
        listening = false
        try? apply()
    }

    /// Re-asserts the session after an interruption — a phone call, Siri, another
    /// app taking the route. iOS does not restore it for you; the app has to ask
    /// again, and until it does the engine runs into silence.
    static func reactivate() throws {
        try apply()
    }

    /// What the route itself adds between a sample being handed to the system and
    /// being heard, in seconds.
    ///
    /// Small on the speaker and anything but small on Bluetooth: AirPods are a
    /// well-known tenth to a fifth of a second all on their own. It matters here
    /// because the mirror now holds the picture to meet the sound — and a
    /// correction that ignored the headphones would put the video ahead by
    /// exactly the amount the headphones cost.
    static var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }

    private static func apply() throws {
        let session = AVAudioSession.sharedInstance()
        guard dictating || listening else {
            // `notifyOthersOnDeactivation` so whatever was playing before Nimlet
            // wanted the speaker picks itself back up.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        if dictating {
            // The options dictation has always used. `.duckOthers` is doing
            // something new here as well as what it did before: the thing being
            // ducked may now be this app's own playback of the Mac, a foot from
            // the microphone that is about to listen for a sentence.
            try session.setCategory(.playAndRecord,
                                    mode: .spokenAudio,
                                    options: [.allowBluetoothHFP, .allowBluetoothA2DP,
                                              .defaultToSpeaker, .duckOthers])
        } else {
            // `.playback`, which is the category that keeps playing with the
            // screen locked and the app in the background — the whole point of
            // being able to hear the Mac at all. `.default` mode rather than
            // `.spokenAudio`: what comes over is as often music or a video as it
            // is a voice, and `.spokenAudio` asks the system to treat it as a
            // podcast, which changes how other apps interrupt it.
            try session.setCategory(.playback, mode: .default, options: [])
        }
        try session.setActive(true)
    }
}
