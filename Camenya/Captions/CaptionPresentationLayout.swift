import CoreGraphics
import UIKit

struct CaptionPresentationLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        let fontSize: CGFloat
        let padding: CGFloat
        let cornerRadius: CGFloat
        let minimumContainerHeight: CGFloat
    }

    static let contentSafeRegionRuleVersion = 1
    static let horizontalInsetFraction: CGFloat = 0.08
    static let verticalInsetFraction: CGFloat = 0.10
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

    static func contentSafeRegion(in canvas: CGSize) -> CGRect {
        CGRect(
            x: canvas.width * horizontalInsetFraction,
            y: canvas.height * verticalInsetFraction,
            width: canvas.width * (1 - horizontalInsetFraction * 2),
            height: canvas.height * (1 - verticalInsetFraction * 2)
        )
    }

    static func previewFrame(
        placement: CaptionPlacementZone,
        width: CGFloat,
        height: CGFloat,
        canvas: CGSize
    ) -> CGRect {
        let safeRegion = contentSafeRegion(in: canvas)
        let minimumCenterY = safeRegion.minY + height / 2
        let maximumCenterY = safeRegion.maxY - height / 2
        let requestedCenterY = canvas.height * centerYFraction(for: placement)
        let centerY = min(maximumCenterY, max(minimumCenterY, requestedCenterY))
        return CGRect(
            x: (canvas.width - width) / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    static func coreAnimationFrame(
        placement: CaptionPlacementZone,
        width: CGFloat,
        height: CGFloat,
        canvas: CGSize
    ) -> CGRect {
        // AVVideoCompositionCoreAnimationTool uses a bottom-leading layer space,
        // while SwiftUI preview placement is measured from the top-leading edge.
        let preview = previewFrame(
            placement: placement,
            width: width,
            height: height,
            canvas: canvas
        )
        return CGRect(
            x: preview.minX,
            y: canvas.height - preview.maxY,
            width: preview.width,
            height: preview.height
        )
    }
}

enum CaptionLineComposer {
    static func resolvedText(
        _ text: String,
        font: UIFont,
        maximumWidth: CGFloat
    ) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "" }
        let normalized = words.joined(separator: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = (normalized as NSString).size(withAttributes: attributes).width
        guard width > maximumWidth else { return normalized }

        var best: (score: CGFloat, ratio: CGFloat, text: String)?
        for splitIndex in 1..<words.count {
            let left = words[..<splitIndex].joined(separator: " ")
            let right = words[splitIndex...].joined(separator: " ")
            let leftWidth = (left as NSString).size(withAttributes: attributes).width
            let rightWidth = (right as NSString).size(withAttributes: attributes).width
            guard leftWidth <= maximumWidth, rightWidth <= maximumWidth else { continue }
            let ratio = min(leftWidth, rightWidth) / max(1, max(leftWidth, rightWidth))
            let punctuationBonus: CGFloat = left.last.map { ",.;:!?".contains($0) } == true ? 0.08 : 0
            let orphanPenalty: CGFloat = right.count <= 3 ? 0.22 : 0
            let score = ratio + punctuationBonus - orphanPenalty
            if best == nil || score > best!.score {
                best = (score, ratio, left + "\n" + right)
            }
        }
        guard let best else { return nil }
        guard best.ratio >= 0.65 || words.count == 2 else { return nil }
        return best.text
    }

    static func fits(
        _ text: String,
        configuration: ProjectCaptionConfiguration,
        canvas: CGSize
    ) -> Bool {
        let metrics = CaptionPresentationLayout.metrics(for: canvas)
        let maximumWidth = canvas.width
            * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
            - metrics.padding * 2
        return resolvedText(
            text,
            font: CaptionPresentationTheme.font(configuration: configuration, size: metrics.fontSize),
            maximumWidth: maximumWidth
        ) != nil
    }

    static func fits(_ text: String, style: CaptionStylePreset, canvas: CGSize) -> Bool {
        fits(
            text,
            configuration: ProjectCaptionConfiguration(
                localeIdentifier: "und",
                placement: .lower,
                style: style
            ),
            canvas: canvas
        )
    }
}

enum CaptionPresentationTheme {
    static func font(style: CaptionStylePreset, size: CGFloat) -> UIFont {
        switch style {
        case .impact:
            let base = UIFont.systemFont(ofSize: size, weight: .heavy)
            return base.fontDescriptor.withDesign(.rounded).map {
                UIFont(descriptor: $0, size: size)
            } ?? base
        case .minimal:
            return .systemFont(ofSize: size, weight: .semibold)
        case .clean, .highContrast, .custom:
            return .systemFont(ofSize: size, weight: .bold)
        }
    }

    static func font(configuration: ProjectCaptionConfiguration, size: CGFloat) -> UIFont {
        guard configuration.style == .custom else { return font(style: configuration.style, size: size) }
        let scaledSize = size * {
            switch configuration.customization.fontScale {
            case .small: 0.86
            case .standard: 1
            case .large: 1.14
            }
        }()
        let base = UIFont.systemFont(ofSize: scaledSize, weight: .bold)
        let design: UIFontDescriptor.SystemDesign = {
            switch configuration.customization.fontDesign {
            case .system: .default
            case .rounded: .rounded
            case .serif: .serif
            }
        }()
        return base.fontDescriptor.withDesign(design).map {
            UIFont(descriptor: $0, size: scaledSize)
        } ?? base
    }

    static func backgroundAlpha(style: CaptionStylePreset) -> CGFloat {
        switch style {
        case .highContrast: 0.76
        case .clean: 0.58
        case .impact, .minimal, .custom: 0
        }
    }

    static func usesHighlight(style: CaptionStylePreset) -> Bool {
        style != .minimal
    }

    static func usesHighlight(configuration: ProjectCaptionConfiguration) -> Bool {
        configuration.style == .custom
            ? configuration.customization.highlighting != .none
            : usesHighlight(style: configuration.style)
    }

    static func textColor(configuration: ProjectCaptionConfiguration) -> UIColor {
        guard configuration.style == .custom else { return .white }
        switch configuration.customization.textColor {
        case .white: return .white
        case .yellow: return .systemYellow
        }
    }

    static func accentColor(configuration: ProjectCaptionConfiguration) -> UIColor {
        guard configuration.style == .custom else { return .systemYellow }
        switch configuration.customization.accentColor {
        case .yellow: return .systemYellow
        case .cyan: return .systemCyan
        case .green: return .systemGreen
        case .pink: return .systemPink
        }
    }

    static func backgroundAlpha(configuration: ProjectCaptionConfiguration) -> CGFloat {
        guard configuration.style == .custom else {
            return backgroundAlpha(style: configuration.style)
        }
        guard configuration.customization.background == .roundedBox else { return 0 }
        switch configuration.customization.containerOpacity {
        case .light: return 0.38
        case .medium: return 0.58
        case .strong: return 0.76
        }
    }

    static func usesShadow(configuration: ProjectCaptionConfiguration) -> Bool {
        if configuration.style == .custom {
            return configuration.customization.background == .shadow
        }
        return configuration.style == .impact || configuration.style == .minimal
    }
}
