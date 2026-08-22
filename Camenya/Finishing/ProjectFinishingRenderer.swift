@preconcurrency import AVFoundation
import QuartzCore
import UIKit

@MainActor
struct ProjectFinishingRenderer {
    struct LayerTree {
        let parent: CALayer
        let video: CALayer
        let presentation: CALayer
    }

    func install(
        timeline: ProjectFinishingTimeline,
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
        timeline: ProjectFinishingTimeline,
        canvas: CGSize
    ) -> LayerTree {
        let parent = CALayer()
        let video = CALayer()
        let presentation = CALayer()
        parent.frame = CGRect(origin: .zero, size: canvas)
        video.frame = parent.frame
        presentation.frame = parent.frame
        parent.addSublayer(video)
        parent.addSublayer(presentation)

        for overlay in timeline.textOverlays {
            let layer = makeTextLayer(overlay: overlay, canvas: canvas, previewCoordinates: false)
            layer.name = "text-overlay"
            addVisibility(
                to: layer,
                range: overlay.range,
                duration: timeline.duration,
                key: "textOverlayVisibility"
            )
            presentation.addSublayer(layer)
        }

        if let captions = timeline.captions, !captions.cues.isEmpty {
            let captionTree = CaptionBurnInRenderer().makeLayerTree(
                timeline: captions,
                canvas: canvas
            )
            for layer in captionTree.overlay.sublayers ?? [] {
                layer.removeFromSuperlayer()
                layer.name = "caption"
                presentation.addSublayer(layer)
            }
        }
        return LayerTree(parent: parent, video: video, presentation: presentation)
    }

    func makePreviewLayer(
        overlay: ProjectTextOverlay,
        canvas: CGSize
    ) -> CALayer {
        let layer = makeTextLayer(overlay: overlay, canvas: canvas, previewCoordinates: true)
        layer.name = "text-overlay"
        layer.opacity = 1
        return layer
    }

    func previewFrame(overlay: ProjectTextOverlay, canvas: CGSize) -> CGRect {
        makeTextLayer(overlay: overlay, canvas: canvas, previewCoordinates: true).frame
    }

    private func makeTextLayer(
        overlay: ProjectTextOverlay,
        canvas: CGSize,
        previewCoordinates: Bool
    ) -> CALayer {
        let metrics = CaptionPresentationLayout.metrics(for: canvas)
        let font = StaticTextPresentation.font(
            for: overlay.appearance,
            baseSize: metrics.fontSize
        )
        let safeRegion = CaptionPresentationLayout.contentSafeRegion(in: canvas)
        let padding = metrics.padding * 0.8
        let maximumTextWidth = max(1, safeRegion.width - padding * 2)
        let resolvedText = CaptionLineComposer.resolvedText(
            overlay.text,
            font: font,
            maximumWidth: maximumTextWidth
        ) ?? overlay.text
        let attributed = StaticTextPresentation.attributedText(
            resolvedText,
            appearance: overlay.appearance,
            font: font
        )
        let textBounds = attributed.boundingRect(
            with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let naturalWidth = min(
            safeRegion.width,
            max(1, ceil(textBounds.width) + padding * 2)
        )
        let naturalHeight = max(
            metrics.minimumContainerHeight * 0.72,
            ceil(textBounds.height) + padding * 2
        )
        let fitScale = min(1, safeRegion.height / naturalHeight)
        let width = naturalWidth * fitScale
        let height = naturalHeight * fitScale
        let requestedCenter = CGPoint(
            x: safeRegion.minX + safeRegion.width * overlay.center.x,
            y: safeRegion.minY + safeRegion.height * overlay.center.y
        )
        let center = CGPoint(
            x: min(safeRegion.maxX - width / 2, max(safeRegion.minX + width / 2, requestedCenter.x)),
            y: min(safeRegion.maxY - height / 2, max(safeRegion.minY + height / 2, requestedCenter.y))
        )
        let previewFrame = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )

        let container = CALayer()
        container.frame = previewCoordinates
            ? previewFrame
            : CGRect(
                x: previewFrame.minX,
                y: canvas.height - previewFrame.maxY,
                width: previewFrame.width,
                height: previewFrame.height
            )
        if overlay.appearance.background == .roundedBox {
            container.backgroundColor = UIColor.black.withAlphaComponent(0.58).cgColor
            container.cornerRadius = metrics.cornerRadius * fitScale
        }
        container.opacity = 0

        let content = CALayer()
        content.anchorPoint = .zero
        content.position = .zero
        content.bounds = CGRect(x: 0, y: 0, width: naturalWidth, height: naturalHeight)
        content.setAffineTransform(CGAffineTransform(scaleX: fitScale, y: fitScale))

        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.contentsScale = 1
        textLayer.isWrapped = true
        textLayer.truncationMode = .none
        textLayer.alignmentMode = StaticTextPresentation.alignmentMode(overlay.appearance.alignment)
        textLayer.frame = CGRect(
            x: padding,
            y: max(0, (naturalHeight - ceil(textBounds.height)) / 2),
            width: naturalWidth - padding * 2,
            height: ceil(textBounds.height) + 4
        )
        if overlay.appearance.background == .shadow {
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.9
            textLayer.shadowRadius = 4
            textLayer.shadowOffset = CGSize(width: 0, height: 2)
        }
        content.addSublayer(textLayer)
        container.addSublayer(content)
        return container
    }

    private func addVisibility(
        to layer: CALayer,
        range: ProjectTimeRange,
        duration: TimeInterval,
        key: String
    ) {
        guard duration > 0 else { return }
        let start = max(0, min(1, range.start.seconds / duration))
        let end = max(start, min(1, range.end.seconds / duration))
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if start == 0 {
            animation.values = end < 1 ? [1, 0, 0] : [1, 0]
            animation.keyTimes = end < 1 ? [0, NSNumber(value: end), 1] : [0, 1]
        } else {
            animation.values = end < 1 ? [0, 1, 0, 0] : [0, 1, 0]
            animation.keyTimes = end < 1
                ? [0, NSNumber(value: start), NSNumber(value: end), 1]
                : [0, NSNumber(value: start), 1]
        }
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .discrete
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }
}
