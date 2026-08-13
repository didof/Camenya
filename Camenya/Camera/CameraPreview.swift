import AVFoundation
import SwiftUI
import UIKit

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        controller.attachPreview(to: view.previewLayer)
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        if view.previewLayer.session !== controller.session {
            controller.attachPreview(to: view.previewLayer)
        }
    }
}
