import Foundation

enum TakeListProjectAction: Equatable, Sendable {
    case playProject
    case analyzeEdges
    case reviewEdges
    case captionSettings
    case reviewCaptions
    case manageCaptions(takeID: UUID)
    case manageEdges(takeID: UUID)
    case exportProject
}

struct TakeListActionCoordinator: Equatable, Sendable {
    private var pendingAction: TakeListProjectAction?

    mutating func request(_ action: TakeListProjectAction) {
        pendingAction = action
    }

    mutating func consumeNextAction(sheetIsPresented: Bool) -> TakeListProjectAction? {
        guard !sheetIsPresented else { return nil }
        defer { pendingAction = nil }
        return pendingAction
    }
}
