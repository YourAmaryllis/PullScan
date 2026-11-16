import Accelerate
import Foundation

public struct Card: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let set: String
    public let series: String
    public let number: String
    public let total: String
    public let rarity: String
    public let released: String
    public let artist: String

    public init(id: String, name: String, set: String = "", series: String = "", number: String = "",
                total: String = "", rarity: String = "", released: String = "", artist: String = "") {
        self.id = id; self.name = name; self.set = set; self.series = series; self.number = number
        self.total = total; self.rarity = rarity; self.released = released; self.artist = artist
    }
}

public struct Match: Hashable, Sendable {
    public let card: Card
    public let score: Float

    public init(_ card: Card, _ score: Float) { self.card = card; self.score = score }
}

/** Every card's reference embedding; nearest-neighbour search by dot product. */
public final class CardIndex: @unchecked Sendable {
    public let cards: [Card]
    public let dim: Int
    private let vectors: [Float]

    public init(cards: [Card], vectors: [Float], dim: Int) {
        precondition(vectors.count == cards.count * dim)
        self.cards = cards; self.vectors = vectors; self.dim = dim
    }

    public func search(_ query: [Float], k: Int = 5) -> [Match] {
        var scores = [Float](repeating: 0, count: cards.count)
        vectors.withUnsafeBufferPointer { v in
            query.withUnsafeBufferPointer { q in
                vDSP_mmul(v.baseAddress!, 1, q.baseAddress!, 1, &scores, 1,
                          vDSP_Length(cards.count), 1, vDSP_Length(dim))
            }
        }
        var top: [(Int, Float)] = []
        for (row, s) in scores.enumerated() where top.count < k || s > top[top.count - 1].1 {
            let pos = top.firstIndex { $0.1 < s } ?? top.count
            top.insert((row, s), at: pos)
            if top.count > k { top.removeLast() }
        }
        return top.map { Match(cards[$0.0], $0.1) }
    }

    /** Loads model.json, cards.json and index.f16 (float16 little-endian, cards x dim) from [dir]. */
    public static func load(from dir: URL) throws -> CardIndex {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("model.json")))
        guard let dim = (meta as? [String: Any])?["dim"] as? Int else { throw LoadError("model.json has no dim") }
        let cards = try parseCards(Data(contentsOf: dir.appendingPathComponent("cards.json")))
        let vectors = try readVectors(Data(contentsOf: dir.appendingPathComponent("index.f16")), count: cards.count, dim: dim)
        return CardIndex(cards: cards, vectors: vectors, dim: dim)
    }

    public static func parseCards(_ data: Data) throws -> [Card] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LoadError("cards.json is not a list")
        }
        func s(_ o: [String: Any], _ k: String) -> String {
            switch o[k] {
            case let v as String: return v
            case let v as NSNumber: return v.stringValue
            default: return ""
            }
        }
        return arr.map { o in
            Card(id: s(o, "id"), name: s(o, "name"), set: s(o, "set"), series: s(o, "series"),
                 number: s(o, "number"), total: s(o, "total"), rarity: s(o, "rarity"),
                 released: s(o, "released"), artist: s(o, "artist"))
        }
    }

    public static func readVectors(_ data: Data, count: Int, dim: Int) throws -> [Float] {
        guard data.count == count * dim * 2 else {
            throw LoadError("index.f16 is \(data.count) bytes, expected \(count * dim * 2)")
        }
        var out = [Float](repeating: 0, count: count * dim)
        data.withUnsafeBytes { raw in
            out.withUnsafeMutableBytes { dst in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1,
                                        width: vImagePixelCount(count * dim), rowBytes: count * dim * 2)
                var dest = vImage_Buffer(data: dst.baseAddress!, height: 1,
                                         width: vImagePixelCount(count * dim), rowBytes: count * dim * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dest, 0)
            }
        }
        return out
    }
}

public struct LoadError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
