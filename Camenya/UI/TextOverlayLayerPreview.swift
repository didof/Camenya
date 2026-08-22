import SwiftUI
import UIKit

struct TextOverlayLayerPreview: UIViewRepresentable {
    let overlay: ProjectTextOverlay

    func makeUIView(context: Context) -> TextOverlayLayerPreviewView {
        TextOverlayLayerPreviewView()
    }

    func updateUIView(_ view: TextOverlayLayerPreviewView, context: Context) {
        view.overlay = overlay
    }
}

final class TextOverlayLayerPreviewView: UIView {
    var overlay: ProjectTextOverlay? {
        didSet { setNeedsLayout() }
    }

    private var renderedLayer: CALayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        renderedLayer?.removeFromSuperlayer()
        guard bounds.width > 0, bounds.height > 0, let overlay else { return }
        let rendered = ProjectFinishingRenderer().makePreviewLayer(
            overlay: overlay,
            canvas: bounds.size
        )
        layer.addSublayer(rendered)
        renderedLayer = rendered
    }
}
