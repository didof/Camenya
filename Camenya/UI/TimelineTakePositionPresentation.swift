import Foundation

struct TimelineTakePositionPresentation: Equatable, Sendable {
    let positionLabel: String
    let accessibilityLabel: String
    let accessibilityValue: String

    init(currentIndex: Int, totalCount: Int) {
        guard totalCount > 0, currentIndex >= 1, currentIndex <= totalCount else {
            positionLabel = ""
            accessibilityLabel = "Timeline playback position"
            accessibilityValue = "No Take is playing"
            return
        }

        positionLabel = "Take \(currentIndex) of \(totalCount)"
        accessibilityLabel = "Timeline playback position"
        accessibilityValue = "Playing Take \(currentIndex) of \(totalCount)"
    }
}
