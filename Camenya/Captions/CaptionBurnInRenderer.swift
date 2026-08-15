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

        for cue in timeline.cues {
            let base = captionLayer(
                text: attributedCaption(
                    cue.text,
                    highlighting: nil,
                    fontSize: metrics.fontSize
                ),
                placement: timeline.placement,
                style: timeline.style,
                canvas: canvas,
                metrics: metrics
            )
            addVisibility(to: base, range: cue.range, timelineDuration: timeline.duration)
            overlayLayer.addSublayer(base)

            for span in cue.timedSpans {
                guard let highlightedRange = ProjectCaptionOverlayResolver.highlightRange(
                    for: span,
                    in: cue
                ) else { continue }
                let highlight = captionLayer(
                    text: attributedCaption(
                        cue.text,
                        highlighting: highlightedRange,
                        fontSize: metrics.fontSize
                    ),
                    placement: timeline.placement,
                    style: timeline.style,
                    canvas: canvas,
                    metrics: metrics
                )
                addVisibility(to: highlight, range: span.range, timelineDuration: timeline.duration)
                overlayLayer.addSublayer(highlight)
            }
        }
        return LayerTree(parent: parentLayer, video: videoLayer, overlay: overlayLayer)
    }

    private func captionLayer(
        text: NSAttributedString,
        placement: CaptionPlacementZone,
        style: CaptionStylePreset,
        canvas: CGSize,
        metrics: CaptionPresentationLayout.Metrics
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
        container.frame = CaptionPresentationLayout.coreAnimationFrame(
            placement: placement,
            width: width,
            height: height,
            canvas: canvas
        )
        switch style {
        case .highContrast:
            container.backgroundColor = UIColor.black.withAlphaComponent(0.76).cgColor
        }
        container.cornerRadius = metrics.cornerRadius
        container.masksToBounds = true
        container.opacity = 0

        let textLayer = CATextLayer()
        textLayer.string = text
        // Export canvas coordinates are already physical pixels.
        textLayer.contentsScale = 1
        textLayer.isWrapped = true
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
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
        fontSize: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
        )
        if let range, NSMaxRange(range) <= attributed.length {
            attributed.addAttributes([
                .foregroundColor: UIColor.systemYellow,
                .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy)
            ], range: range)
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
