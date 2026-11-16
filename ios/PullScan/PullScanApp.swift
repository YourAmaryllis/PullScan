import AVFoundation
import PullScanCore
import SwiftUI

@main
struct PullScanApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.55, green: 0.75, blue: 1.0))
        }
    }
}

struct RootView: View {
    enum Screen { case scan, collection, settings }

    @Environment(AppModel.self) private var app
    @State private var screen = Screen.scan
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scan: ScanModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .task {
            await app.load()
            // One scan model (and camera session) for the app's lifetime.
            if let embedder = app.embedder, let index = app.index {
                scan = ScanModel(app: app, embedder: embedder, index: index)
            }
        }
        .task {
            if camera == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        // Shown once (until acknowledged), before the first scan.
        .alert("Before you start", isPresented: .constant(!app.disclaimerOk)) {
            Button("I understand") { app.acceptDisclaimer() }
        } message: {
            Text(Disclaimer.text)
        }
    }

    @ViewBuilder private var content: some View {
        switch app.phase {
        case .loading:
            Message("Loading card database…")
        case .failed(let error):
            Message("Could not load the card model:\n\(error)")
        case .ready:
            switch screen {
            case .collection: CollectionView { screen = .scan }
            case .settings: SettingsView { screen = .scan }
            case .scan:
                if camera == .denied || camera == .restricted {
                    Message("PullScan needs the camera to identify cards.") {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if camera == .authorized, let scan {
                    ScanView(scan: scan, onCollection: { screen = .collection }, onSettings: { screen = .settings })
                } else {
                    Message("Waiting for camera access…")
                }
            }
        }
    }
}

struct Message<Action: View>: View {
    let text: String
    let action: Action

    init(_ text: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.text = text
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(text).foregroundStyle(.white).multilineTextAlignment(.center)
            action
        }
        .padding(32)
    }
}
