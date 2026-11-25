import AVFoundation
import SwiftUI
import VisionKit

struct QRScannerView: View {
    enum CameraAccess {
        case checking, available, denied, unavailable
    }

    enum Result {
        case payload(String), unavailable
    }

    typealias ScanHandler = @MainActor (Result) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var access: CameraAccess = .checking

    private let onPayload: @MainActor (String) -> Void
    private let cameraAccess: @MainActor () async -> CameraAccess
    private let makeScanner: @MainActor (@escaping ScanHandler) -> AnyView

    init(onPayload: @escaping @MainActor (String) -> Void,
         cameraAccess: @escaping @MainActor () async -> CameraAccess = Self.currentCameraAccess,
         makeScanner: @escaping @MainActor (@escaping ScanHandler) -> AnyView = {
             AnyView(VisionKitQRScanner(onResult: $0))
         }) {
        self.onPayload = onPayload
        self.cameraAccess = cameraAccess
        self.makeScanner = makeScanner
    }

    var body: some View {
        Group {
            switch access {
            case .checking:
                ProgressView()
            case .available:
                makeScanner { result in
                    switch result {
                    case .payload(let payload): onPayload(payload)
                    case .unavailable: Task { await updateFailedAccess() }
                    }
                }
            case .denied:
                ContentUnavailableView {
                    Image(systemName: "camera.fill")
                } description: {
                    Text("Camera access is off. Allow access in Settings to scan a sign-in code.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            case .unavailable:
                ContentUnavailableView("QR scanning is unavailable.", systemImage: "camera.fill")
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let status = await cameraAccess()
            if !Task.isCancelled { access = status }
        }
    }

    private func updateFailedAccess() async {
        let status = await cameraAccess()
        if !Task.isCancelled { access = status == .denied ? .denied : .unavailable }
    }

    private static func currentCameraAccess() async -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied:
            return .denied
        case .notDetermined:
            guard DataScannerViewController.isSupported else { return .unavailable }
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        case .authorized:
            break
        case .restricted:
            return .unavailable
        @unknown default:
            return .unavailable
        }
        return DataScannerViewController.isSupported && DataScannerViewController.isAvailable ? .available : .unavailable
    }
}

private struct VisionKitQRScanner: UIViewControllerRepresentable {
    let onResult: QRScannerView.ScanHandler

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> ScannerHost {
        let host = ScannerHost()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {
        context.coordinator.onResult = onResult
    }

    static func dismantleUIViewController(_ host: ScannerHost, coordinator: Coordinator) {
        host.coordinator = nil
        host.scanner.delegate = nil
        host.scanner.stopScanning()
    }

    final class ScannerHost: UIViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            recognizesMultipleItems: false
        )
        weak var coordinator: Coordinator?

        override func viewDidLoad() {
            super.viewDidLoad()
            scanner.delegate = coordinator
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Wait for the camera controller to be mounted in the presented sheet.
            coordinator?.start(scanner)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            scanner.stopScanning()
        }
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onResult: QRScannerView.ScanHandler
        private var finished = false

        init(onResult: @escaping QRScannerView.ScanHandler) { self.onResult = onResult }

        func start(_ scanner: DataScannerViewController) {
            guard !finished, !scanner.isScanning else { return }
            do {
                try scanner.startScanning()
            } catch {
                finish(.unavailable, scanner: scanner)
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard case .barcode(let barcode)? = addedItems.first else { return }
            finish(.payload(barcode.payloadStringValue ?? ""), scanner: scanner)
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            finish(.unavailable, scanner: scanner)
        }

        private func finish(_ result: QRScannerView.Result, scanner: DataScannerViewController) {
            guard !finished else { return }
            finished = true
            scanner.stopScanning()
            onResult(result)
        }
    }
}
