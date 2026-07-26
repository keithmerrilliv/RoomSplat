import SwiftUI
import RoomPlan

/// Wraps `RoomCaptureView` and exposes the scan lifecycle to SwiftUI.
struct RoomScannerView: UIViewRepresentable {

    @Binding var isScanning: Bool
    /// Called once when the user finishes scanning and a `CapturedRoom` is produced.
    var onFinish: (CapturedRoom) -> Void
    /// Called if scanning fails.
    var onError: (Error) -> Void

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onError: onError)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.captureSession.delegate = context.coordinator
        context.coordinator.captureView = view
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        if isScanning && !context.coordinator.isRunning {
            let cfg = RoomCaptureSession.Configuration()
            uiView.captureSession.run(configuration: cfg)
            context.coordinator.isRunning = true
        } else if !isScanning && context.coordinator.isRunning {
            uiView.captureSession.stop()
            context.coordinator.isRunning = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, RoomCaptureSessionDelegate {
        weak var captureView: RoomCaptureView?
        var isRunning = false
        let onFinish: (CapturedRoom) -> Void
        let onError: (Error) -> Void

        init(onFinish: @escaping (CapturedRoom) -> Void,
             onError: @escaping (Error) -> Void) {
            self.onFinish = onFinish
            self.onError = onError
        }

        // MARK: - RoomCaptureSessionDelegate

        // RoomPlan invokes this from an arbitrary thread, so it must be
        // nonisolated. Hop back to the main actor before calling out.
        nonisolated func captureSession(_ session: RoomCaptureSession,
                                        didEndWith data: CapturedRoomData,
                                        error: Error?) {
            Task { @MainActor [data] in
                if let error {
                    self.onError(error)
                    return
                }
                do {
                    let builder = RoomBuilder(options: [.beautifyObjects])
                    let room = try await builder.capturedRoom(from: data)
                    self.onFinish(room)
                } catch {
                    self.onError(error)
                }
            }
        }
    }
}
