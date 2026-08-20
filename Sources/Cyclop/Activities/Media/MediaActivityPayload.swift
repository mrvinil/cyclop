import Foundation

struct MediaActivityPayload: Equatable {
    let trackKey: String
    let title: String
    let artist: String
    let album: String
    let sourceName: String?
    let isPlaying: Bool
    let duration: TimeInterval
    let position: TimeInterval
    let canSkip: Bool
}
