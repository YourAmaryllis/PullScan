import CoreML
import CoreVideo
import Foundation

/** Runs Embedder.mlpackage: 224x308 RGB image -> L2-normalized 384-d embedding. */
public final class Embedder: @unchecked Sendable {
    private let model: MLModel

    /** [url] is a compiled model (.mlmodelc), as Xcode puts it in the app bundle. */
    public init(compiledModel url: URL, units: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = units
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /** Compiles an .mlpackage first (tests, tools); the app ships it precompiled. */
    public convenience init(package url: URL, units: MLComputeUnits = .all) throws {
        try self.init(compiledModel: try MLModel.compileModel(at: url), units: units)
    }

    /** [pixels]: Preprocess.width x Preprocess.height, 0xAARRGGBB. */
    public func embed(_ pixels: [UInt32]) throws -> [Float] {
        let buffer = try Self.pixelBuffer(pixels, Preprocess.width, Preprocess.height)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let out = try model.prediction(from: input)
        guard let arr = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw LoadError("model returned no embedding")
        }
        return (0..<arr.count).map { arr[$0].floatValue }
    }

    static func pixelBuffer(_ pixels: [UInt32], _ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else {
            throw LoadError("could not create pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixels[y * w + x]
                let o = y * row + x * 4
                base[o] = UInt8(p & 0xFF)               // B
                base[o + 1] = UInt8((p >> 8) & 0xFF)    // G
                base[o + 2] = UInt8((p >> 16) & 0xFF)   // R
                base[o + 3] = 0xFF
            }
        }
        return pb
    }
}
