@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import UIKit

@MainActor
struct CaptionBurnInRenderer {
    struct LayerTree {
        let parent: CALayer
        let video: CALayer
        let overlay: CALayer
    }

    func install(
        timeline: ProjectCaptionExportTimeline,
        canvas: CGSize,
        videoComposition: AVMutableVideoComposition
    ) {
        let tree = makeLayerTree(timeline: timeline, canvas: canvas)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: tree.video,
            in: tree.parent
        )
    }

    func makeLayerTree(
        timeline: ProjectCaptionExportTimeline,
        canvas: CGSize
    ) -> LayerTree {
        let metrics = CaptionPresentationLayout.metrics(for: canvas)
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        let overlayLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: canvas)
        videoLayer.frame = parentLayer.frame
        overlayLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "und",
            placement: timeline.placement,
            style: timeline.style,
            customization: timeline.customization
        )

        for cue in timeline.cues {
            let base = captionLayer(
                text: attributedCaption(
                    cue.text,
                    highlighting: nil,
                    fontSize: metrics.fontSize,
                    configuration: configuration,
                    maximumLineWidth: canvas.width * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
                        - metrics.padding * 2
                ),
                configuration: configuration,
                canvas: canvas,
                metrics: metrics
            )
            addVisibility(to: base, range: cue.range, timelineDuration: timeline.duration)
            overlayLayer.addSublayer(base)

            for span in cue.timedSpans {
                if !CaptionPresentationTheme.usesHighlight(configuration: configuration) { continue }
                guard let highlightedRange = ProjectCaptionOverlayResolver.highlightRange(
                    for: span,
                    in: cue
                ) else { continue }
                let highlight = captionLayer(
                    text: attributedCaption(
                        cue.text,
                        highlighting: highlightedRange,
                        fontSize: metrics.fontSize,
                        configuration: configuration,
                        maximumLineWidth: canvas.width * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
                            - metrics.padding * 2
                    ),
                    configuration: configuration,
                    canvas: canvas,
                    metrics: metrics
                )
                addVisibility(to: highlight, range: span.range, timelineDuration: timeline.duration)
                overlayLayer.addSublayer(highlight)
            }
        }
        return LayerTree(parent: parentLayer, video: videoLayer, overlay: overlayLayer)
    }

    func makePreviewLayer(
        cue: ProjectCaptionExportCue,
        configuration: ProjectCaptionConfiguration,
        canvas: CGSize,
        activeTime: TimeInterval?
    ) -> CALayer {
        let metrics = CaptionPresentationLayout.metrics(for: canvas)
        let highlightedRange = CaptionPresentationTheme.usesHighlight(configuration: configuration)
            ? activeTime.flatMap { time in
            cue.timedSpans.first(where: {
                time >= $0.range.start.seconds && time < $0.range.end.seconds
            }).flatMap { ProjectCaptionOverlayResolver.highlightRange(for: $0, in: cue) }
            }
            : nil
        let layer = captionLayer(
            text: attributedCaption(
                cue.text,
                highlighting: highlightedRange,
                fontSize: metrics.fontSize,
                configuration: configuration,
                maximumLineWidth: canvas.width
                    * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
                    - metrics.padding * 2
            ),
            configuration: configuration,
            canvas: canvas,
            metrics: metrics,
            previewCoordinates: true
        )
        layer.opacity = 1
        return layer
    }

    private func captionLayer(
        text: NSAttributedString,
        configuration: ProjectCaptionConfiguration,
        canvas: CGSize,
        metrics: CaptionPresentationLayout.Metrics,
        previewCoordinates: Bool = false
    ) -> CALayer {
        let padding = metrics.padding
        let maximumWidth = canvas.width * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
        let textBounds = text.boundingRect(
            with: CGSize(width: maximumWidth - padding * 2, height: canvas.height * 0.3),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let width = min(maximumWidth, max(padding * 2 + 1, ceil(textBounds.width) + padding * 2))
        let height = min(
            canvas.height * CaptionPresentationLayout.maximumHeightFraction,
            max(metrics.minimumContainerHeight, ceil(textBounds.height) + padding * 2)
        )

        let container = CALayer()
        container.frame = previewCoordinates
            ? CaptionPresentationLayout.previewFrame(
                placement: configuration.placement,
                width: width,
                height: height,
                canvas: canvas
            )
            : CaptionPresentationLayout.coreAnimationFrame(
                placement: configuration.placement,
                width: width,
                height: height,
                canvas: canvas
            )
        container.backgroundColor = UIColor.black.withAlphaComponent(
            CaptionPresentationTheme.backgroundAlpha(configuration: configuration)
        ).cgColor
        container.cornerRadius = metrics.cornerRadius
        container.masksToBounds = true
        container.opacity = 0

        let textLayer = CATextLayer()
        textLayer.string = text
        // Export canvas coordinates are already physical pixels.
        textLayer.contentsScale = 1
        textLayer.isWrapped = true
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .none
        if CaptionPresentationTheme.usesShadow(configuration: configuration) {
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.9
            textLayer.shadowRadius = configuration.style == .impact ? 4 : 3
            textLayer.shadowOffset = CGSize(width: 0, height: 2)
        }
        textLayer.frame = CGRect(
            x: padding,
            y: max(0, (height - ceil(textBounds.height)) / 2),
            width: width - padding * 2,
            height: min(ceil(textBounds.height) + 4, height)
        )
        container.addSublayer(textLayer)
        return container
    }

    private func attributedCaption(
        _ text: String,
        highlighting range: NSRange?,
        fontSize: CGFloat,
        configuration: ProjectCaptionConfiguration,
        maximumLineWidth: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let baseFont = CaptionPresentationTheme.font(configuration: configuration, size: fontSize)
        let resolvedText = CaptionLineComposer.resolvedText(
            text,
            font: baseFont,
            maximumWidth: maximumLineWidth
        ) ?? text
        let baseAttributes: [NSAttributedString.Key: Any]
        if configuration.style == .custom {
            baseAttributes = StaticTextPresentation.attributes(
                appearance: TextAppearance(captionCustomization: configuration.customization),
                font: baseFont
            )
        } else {
            baseAttributes = [
                .font: baseFont,
                .foregroundColor: CaptionPresentationTheme.textColor(configuration: configuration),
                .paragraphStyle: paragraph
            ]
        }
        let attributed = NSMutableAttributedString(
            string: resolvedText,
            attributes: baseAttributes
        )
        if let range, NSMaxRange(range) <= attributed.length {
            let highlightAttributes: [NSAttributedString.Key: Any]
            let usesPill = configuration.style == .impact
                || (configuration.style == .custom && configuration.customization.highlighting == .pill)
            if usesPill {
                highlightAttributes = [
                    .foregroundColor: UIColor.black,
                    .backgroundColor: CaptionPresentationTheme.accentColor(configuration: configuration),
                    .font: CaptionPresentationTheme.font(configuration: configuration, size: fontSize)
                ]
            } else {
                highlightAttributes = [
                    .foregroundColor: CaptionPresentationTheme.accentColor(configuration: configuration),
                    .font: CaptionPresentationTheme.font(configuration: configuration, size: fontSize)
                ]
            }
            attributed.addAttributes(highlightAttributes, range: range)
        }
        return attributed
    }

    private func addVisibility(
        to layer: CALayer,
        range: TakeRange,
        timelineDuration: TimeInterval
    ) {
        guard timelineDuration > 0 else { return }
        let start = max(0, min(1, range.start.seconds / timelineDuration))
        let end = max(start, min(1, range.end.seconds / timelineDuration))
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if start == 0 {
            animation.values = end < 1 ? [1, 0, 0] : [1, 0]
            animation.keyTimes = end < 1
                ? [0, NSNumber(value: end), 1]
                : [0, 1]
        } else {
            animation.values = end < 1 ? [0, 1, 0, 0] : [0, 1, 0]
            animation.keyTimes = end < 1
                ? [0, NSNumber(value: start), NSNumber(value: end), 1]
                : [0, NSNumber(value: start), 1]
        }
        animation.duration = timelineDuration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .discrete
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "captionVisibility")
    }
}
