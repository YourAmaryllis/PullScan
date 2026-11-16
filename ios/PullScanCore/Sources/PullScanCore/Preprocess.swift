import Foundation

/**
 * Turns a cropped card image into the model input, exactly like the Android
 * Preprocess (and so like the Python pipeline the index was built with).
 *
 * Contract (embeddings/<tag>/preprocess.json): RGB, stretched to 224x308 with
 * PIL-style bilinear resampling. Scaling to [0,1], mean/std and L2 normalization
 * are inside the Core ML model.
 *
 * Pixels are packed 0xAARRGGBB in a UInt32, row by row.
 */
public enum Preprocess {
    public static let width = 224
    public static let height = 308

    /** Resize the way PIL's Image.resize(BILINEAR) does: a triangle filter whose
     *  support widens when shrinking, horizontal pass first, with 8-bit rounding
     *  between passes. */
    public static func resize(_ src: [UInt32], _ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int) -> [UInt32] {
        var tmp = [UInt32](repeating: 0, count: dw * sh)
        pass(src, sw, sh, &tmp, dw, horizontal: true)
        var out = [UInt32](repeating: 0, count: dw * dh)
        pass(tmp, dw, sh, &out, dh, horizontal: false)
        return out
    }

    private static func pass(_ src: [UInt32], _ sw: Int, _ sh: Int, _ dst: inout [UInt32], _ outSize: Int,
                             horizontal: Bool) {
        let inSize = horizontal ? sw : sh
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1.0)
        let support = filterScale  // bilinear filter support is 1.0
        let lines = horizontal ? sh : sw
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                for o in 0..<outSize {
                    let center = (Double(o) + 0.5) * scale
                    let lo = max(Int(center - support + 0.5), 0)
                    let hi = min(Int(center + support + 0.5), inSize)
                    var weights = (0..<(hi - lo)).map { i -> Double in
                        let x = abs((Double(i + lo) - center + 0.5) / filterScale)
                        return x < 1.0 ? 1.0 - x : 0.0
                    }
                    let total = weights.reduce(0, +)
                    if total > 0 { for i in weights.indices { weights[i] /= total } }
                    for line in 0..<lines {
                        var r = 0.0, g = 0.0, b = 0.0
                        for i in weights.indices {
                            let p = horizontal ? s[line * sw + lo + i] : s[(lo + i) * sw + line]
                            let w = weights[i]
                            r += Double((p >> 16) & 0xFF) * w
                            g += Double((p >> 8) & 0xFF) * w
                            b += Double(p & 0xFF) * w
                        }
                        let px = 0xFF00_0000 | (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
                        if horizontal { d[line * outSize + o] = px } else { d[o * sw + line] = px }
                    }
                }
            }
        }
    }

    // Kotlin's roundToInt rounds half up (toward positive infinity).
    private static func clamp(_ v: Double) -> UInt32 { UInt32(min(max((v + 0.5).rounded(.down), 0), 255)) }
}
