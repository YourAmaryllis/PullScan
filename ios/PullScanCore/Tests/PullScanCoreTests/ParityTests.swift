import PullScanCore
import XCTest

/**
 * The iOS pipeline (Swift resize + Core ML) must give the same embedding as
 * Python (PIL resize + PyTorch) for the same image, or the phone's queries won't
 * line up with the index built on the laptop. Uses the Android parity fixtures
 * (ml/export_android.py; card images, so not in the public repo) and the Core ML
 * model (scripts/fetch_models.sh --ios). Skipped when either is missing.
 */
final class ParityTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardized
    private var fixtures: URL { repo.appendingPathComponent("android/app/src/test/resources/parity") }
    private var model: URL { repo.appendingPathComponent("ios/PullScan/Model/Embedder.mlpackage") }
    private var assets: URL { repo.appendingPathComponent("android/app/src/main/assets") }

    func testSwiftPipelineMatchesPython() throws {
        let reference = fixtures.appendingPathComponent("reference.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: reference.path), "parity fixtures not generated")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path), "model missing (fetch_models.sh --ios)")
        let embedder = try Embedder(package: model, units: .cpuOnly)
        let index = try CardIndex.load(from: assets)
        for line in try String(contentsOf: reference, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: " ")
            let id = String(parts[0])
            let ref = parts.dropFirst().map { Float($0)! }
            let (px, w, h) = try readRgb(fixtures.appendingPathComponent("\(id).rgb"))
            let emb = try embedder.embed(Preprocess.resize(px, w, h, Preprocess.width, Preprocess.height))
            XCTAssertEqual(emb.count, ref.count)
            let cos = zip(ref, emb).reduce(0) { $0 + Double($1.0 * $1.1) }
            let top = index.search(emb, k: 1).first
            print("\(id) cosine vs python = \(cos), top-1 \(top?.card.id ?? "-") \(top?.score ?? 0)")
            XCTAssertGreaterThan(cos, 0.99, id)   // the Core ML model runs in float16
            XCTAssertEqual(top?.card.id, id)
        }
    }

    func testHalfFloatIndexDecoding() throws {
        let halves: [UInt16] = [0x3C00, 0xC000, 0x3800, 0x0001]
        let data = halves.withUnsafeBytes { Data($0) }
        XCTAssertEqual(try CardIndex.readVectors(data, count: 1, dim: 4), [1, -2, 0.5, 5.9604645e-8])
    }

    /** "<w> <h>\n" + raw RGB bytes -> 0xAARRGGBB pixels. */
    private func readRgb(_ url: URL) throws -> ([UInt32], Int, Int) {
        let bytes = [UInt8](try Data(contentsOf: url))
        let nl = bytes.firstIndex(of: 0x0A)!
        let wh = String(decoding: bytes[..<nl], as: UTF8.self).split(separator: " ").map { Int($0)! }
        let px = (0..<(wh[0] * wh[1])).map { i -> UInt32 in
            let o = nl + 1 + i * 3
            return 0xFF00_0000 | UInt32(bytes[o]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2])
        }
        return (px, wh[0], wh[1])
    }
}
