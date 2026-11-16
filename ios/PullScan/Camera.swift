import AVFoundation
import CoreGraphics
import PullScanCore
import os
import SwiftUI
import UIKit

/** Card outline on screen: card-shaped (63x88mm), centered a little above middle. Same as Android. */
func guideRect(_ size: CGSize) -> CGRect {
    var w = size.width * 0.78
    var h = w * 88 / 63
    if h > size.height * 0.62 { h = size.height * 0.62; w = h * 63 / 88 }
    return CGRect(x: size.width / 2 - w / 2, y: size.height * 0.40 - h / 2, width: w, height: h)
}

struct ScanResult {
    let matches: [Match]
    let input: CGImage?   // exactly what the model saw (224x308)
    let millis: Int
}

/**
 * Runs the back camera and, for each frame, crops the guide region, embeds it
 * and looks it up. The preview uses aspect fill, so the on-screen guide maps to
 * the frame by the same scale/offset the preview applies.
 */
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pullscan.analysis")
    private let shared = OSAllocatedUnfairLock(initialState: (view: CGSize.zero, paused: false))
    private let embedder: Embedder
    private let index: CardIndex
    var onResult: (@MainActor (ScanResult) -> Void)?

    init(embedder: Embedder, index: CardIndex) {
        self.embedder = embedder
        self.index = index
    }

    var viewSize: CGSize {
        get { shared.withLock { $0.view } }
        set { shared.withLock { $0.view = newValue } }
    }

    var paused: Bool {
        get { shared.withLock { $0.paused } }
        set { shared.withLock { $0.paused = newValue } }
    }

    /** False when there's no camera (simulator). */
    func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true   // only the latest frame is analysed
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Portrait frames, so the frame and the screen share one coordinate system.
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        return true
    }

    func start() { queue.async { [session] in if !session.isRunning { session.startRunning() } } }
    func stop() { queue.async { [session] in if session.isRunning { session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (view, paused) = shared.withLock { ($0.view, $0.paused) }
        guard !paused, view.width > 0, view.height > 0, let frame = CMSampleBufferGetImageBuffer(sample) else { return }
        let start = uptimeMs()
        guard let (px, w, h) = cropGuide(frame, view) else { return }
        let resized = Preprocess.resize(px, w, h, Preprocess.width, Preprocess.height)
        guard let emb = try? embedder.embed(resized) else { return }
        let result = ScanResult(matches: index.search(emb, k: 5), input: Self.image(resized),
                                millis: Int(uptimeMs() - start))
        Task { @MainActor [onResult] in onResult?(result) }
    }

    /** The guide region of the frame as 0xAARRGGBB pixels. */
    private func cropGuide(_ frame: CVPixelBuffer, _ view: CGSize) -> ([UInt32], Int, Int)? {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        let scale = max(view.width / CGFloat(fw), view.height / CGFloat(fh))
        let dx = (view.width - CGFloat(fw) * scale) / 2
        let dy = (view.height - CGFloat(fh) * scale) / 2
        let g = guideRect(view)
        let left = min(max(Int(((g.minX - dx) / scale).rounded()), 0), fw - 1)
        let top = min(max(Int(((g.minY - dy) / scale).rounded()), 0), fh - 1)
        let right = min(max(Int(((g.maxX - dx) / scale).rounded()), left + 1), fw)
        let bottom = min(max(Int(((g.maxY - dy) / scale).rounded()), top + 1), fh)
        let w = right - left, h = bottom - top
        guard w >= 32, h >= 32, let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(frame)
        var out = [UInt32](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                // BGRA bytes read as a little-endian UInt32 are already 0xAARRGGBB.
                let src = (base + (top + y) * row + left * 4).assumingMemoryBound(to: UInt32.self)
                for x in 0..<w { dst[y * w + x] = src[x] | 0xFF00_0000 }
            }
        }
        return (out, w, h)
    }

    private static func image(_ px: [UInt32]) -> CGImage? {
        var copy = px
        return copy.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: Preprocess.width, height: Preprocess.height, bitsPerComponent: 8,
                      bytesPerRow: Preprocess.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
    }
}

/** The live camera picture, aspect-filled like the guide math expects. */
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        if let c = v.preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
