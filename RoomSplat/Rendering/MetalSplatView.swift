import SwiftUI
import MetalKit

/// SwiftUI host for the splat viewer. Owns the renderer and forwards orbit gestures.
struct MetalSplatView: UIViewRepresentable {
    let splats: [Splat]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.04, 0.05, 0.07, 1.0)
        view.preferredFramesPerSecond = 60
        view.isOpaque = true

        let renderer = SplatRenderer(device: view.device!,
                                     colorPixelFormat: view.colorPixelFormat,
                                     depthPixelFormat: view.depthStencilPixelFormat)
        renderer.setSplats(splats)
        context.coordinator.renderer = renderer
        view.delegate = context.coordinator

        // Gestures
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.setSplats(splats)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: SplatRenderer?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            renderer?.render(view: view)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = g.view else { return }
            let t = g.translation(in: v)
            g.setTranslation(.zero, in: v)
            r.orbitYaw   -= Float(t.x) * 0.005
            r.orbitPitch += Float(t.y) * 0.005
            r.orbitPitch = max(-1.5, min(1.5, r.orbitPitch))
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let r = renderer else { return }
            r.orbitRadius /= Float(g.scale)
            r.orbitRadius = max(0.3, min(60, r.orbitRadius))
            g.scale = 1
        }
    }
}
