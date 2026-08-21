import SwiftUI
import UIKit

struct CaptionLayerPreview: UIViewRepresentable {
    let cue: ProjectCaptionExportCue
    let configuration: ProjectCaptionConfiguration
    let activeTime: TimeInterval?

    func makeUIView(context: Context) -> CaptionLayerPreviewView {
        CaptionLayerPreviewView()
    }

    func updateUIView(_ view: CaptionLayerPreviewView, context: Context) {
        view.presentation = (cue, configuration, activeTime)
    }
}

final class CaptionLayerPreviewView: UIView {
    var presentation: (ProjectCaptionExportCue, ProjectCaptionConfiguration, TimeInterval?)? {
        didSet { setNeedsLayout() }
    }

    private var captionLayer: CALayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        captionLayer?.removeFromSuperlayer()
        guard bounds.width > 0, bounds.height > 0, let presentation else { return }
        let rendered = CaptionBurnInRenderer().makePreviewLayer(
            cue: presentation.0,
            configuration: presentation.1,
            canvas: bounds.size,
            activeTime: presentation.2
        )
        layer.addSublayer(rendered)
        captionLayer = rendered
    }
}
