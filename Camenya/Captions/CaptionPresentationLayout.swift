import CoreGraphics

struct CaptionPresentationLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        let fontSize: CGFloat
        let padding: CGFloat
        let cornerRadius: CGFloat
        let minimumContainerHeight: CGFloat
    }

    static let horizontalInsetFraction: CGFloat = 0.08
    static let maximumHeightFraction: CGFloat = 0.24

    private static let referenceShortEdge: CGFloat = 1080
    private static let referenceFontSize: CGFloat = 58
    private static let referencePadding: CGFloat = 24
    private static let referenceCornerRadius: CGFloat = 18
    private static let referenceMinimumContainerHeight: CGFloat = 110

    static func metrics(for canvas: CGSize) -> Metrics {
        let shortEdge = max(1, min(abs(canvas.width), abs(canvas.height)))
        let scale = shortEdge / referenceShortEdge
        return Metrics(
            fontSize: referenceFontSize * scale,
            padding: referencePadding * scale,
            cornerRadius: referenceCornerRadius * scale,
            minimumContainerHeight: referenceMinimumContainerHeight * scale
        )
    }

    static func centerYFraction(for placement: CaptionPlacementZone) -> CGFloat {
        switch placement {
        case .upper: 0.18
        case .center: 0.5
        case .lower: 0.82
        }
    }

    static func coreAnimationFrame(
        placement: CaptionPlacementZone,
        width: CGFloat,
        height: CGFloat,
        canvas: CGSize
    ) -> CGRect {
        // AVVideoCompositionCoreAnimationTool uses a bottom-leading layer space,
        // while SwiftUI preview placement is measured from the top-leading edge.
        let coreAnimationCenterY = 1 - centerYFraction(for: placement)
        return CGRect(
            x: (canvas.width - width) / 2,
            y: canvas.height * coreAnimationCenterY - height / 2,
            width: width,
            height: height
        )
    }
}
