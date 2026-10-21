import Foundation
import MediaPlayer

/// Puts the Mac on the lock screen while you are listening to it.
///
/// Not decoration. The premise of this feature is that the phone is not in your
/// hand — it is on a shelf in another room, or in a pocket — and the thing you
/// will want most is to stop it without unlocking anything. Registering as
/// what's-playing is how iOS is asked for that: the Control Centre tile, the
/// lock screen, a squeeze of an AirPod stem and the pause button on a car stereo
/// all arrive here.
///
/// It earns its keep a second way, too. An app claiming the Now Playing slot is
/// an app iOS treats as a media player, which is what makes `.playback` in the
/// background behave the way a podcast does rather than the way a socket does.
@MainActor
enum NowPlaying {

    private static var isRegistered = false

    /// What the pause button does. Held rather than passed, because the command
    /// centre's handlers outlive any one call.
    private static var onStop: (() -> Void)?

    static func begin(hostName: String, stop: @escaping () -> Void) {
        onStop = stop
        register()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: hostName,
            MPMediaItemPropertyArtist: "Nimlet",
            // No elapsed time and no duration: this is not a track with a
            // position in it, and iOS draws a live indicator instead of a
            // scrubber nobody can use.
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    static func end() {
        guard isRegistered else { return }
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onStop = nil
    }

    /// Whether the samples are actually arriving, as distinct from whether
    /// listening is switched on. A link that has gone quiet should read as
    /// paused on the lock screen rather than as playing silence.
    static func note(playing: Bool) {
        guard isRegistered, onStop != nil else { return }
        let state: MPNowPlayingPlaybackState = playing ? .playing : .paused
        guard MPNowPlayingInfoCenter.default().playbackState != state else { return }
        MPNowPlayingInfoCenter.default().playbackState = state
    }

    private static func register() {
        guard !isRegistered else { return }
        isRegistered = true
        let centre = MPRemoteCommandCenter.shared()
        // Pause, stop and play all land in the same place. There is nothing to
        // resume from — a live stream has no position — so the only honest
        // meaning of any of them is "stop listening", and the one of them a
        // given piece of hardware sends is not something to guess at.
        for command in [centre.pauseCommand, centre.stopCommand, centre.togglePlayPauseCommand] {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in onStop?() }
                return .success
            }
        }
        // Explicitly off, so the lock screen does not offer buttons that would
        // do nothing.
        centre.playCommand.isEnabled = false
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
        centre.changePlaybackPositionCommand.isEnabled = false
    }
}
