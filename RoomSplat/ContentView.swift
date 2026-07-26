import SwiftUI
import RoomPlan

struct ContentView: View {
    enum Phase: Equatable {
        case intro
        case scanning
        case viewing(splats: [Splat])
        case error(String)
    }

    @State private var phase: Phase = .intro
    @State private var isScanning = false
    @State private var generator = SplatGenerator()

    var body: some View {
        ZStack {
            switch phase {
            case .intro:
                introScreen
            case .scanning:
                scanScreen
            case .viewing(let splats):
                viewerScreen(splats: splats)
            case .error(let message):
                errorScreen(message: message)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    // MARK: - Screens

    private var introScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("RoomSplat")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Scan a room with ARKit + RoomPlan, then view it as a Gaussian splat cloud rendered in Metal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                guard RoomCaptureSession.isSupported else {
                    phase = .error("This device doesn't support RoomPlan. A LiDAR-equipped iPhone or iPad Pro is required.")
                    return
                }
                isScanning = true
                phase = .scanning
            } label: {
                Text("Start scanning")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    private var scanScreen: some View {
        ZStack(alignment: .bottom) {
            RoomScannerView(
                isScanning: $isScanning,
                onFinish: { room in
                    let splats = generator.splats(from: room)
                    phase = .viewing(splats: splats)
                },
                onError: { error in
                    phase = .error(error.localizedDescription)
                }
            )
            .ignoresSafeArea()

            HStack {
                Button("Cancel") {
                    isScanning = false
                    phase = .intro
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Spacer()

                Button("Done") {
                    isScanning = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private func viewerScreen(splats: [Splat]) -> some View {
        ZStack(alignment: .top) {
            MetalSplatView(splats: splats)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 4) {
                Text("\(splats.count) splats")
                    .font(.headline)
                Text("Drag to orbit · pinch to zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)

            VStack {
                Spacer()
                Button("Scan another room") {
                    phase = .intro
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 32)
            }
        }
    }

    private func errorScreen(message: String) -> some View {
        VStack(spacing: 16) {
            Text("Something went wrong").font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Try again") { phase = .intro }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
    }
}
