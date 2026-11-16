import Foundation

/** Estimated prices for one card. Keys are TCGplayer variants / Cardmarket fields, as in prices.json. */
public struct CardPrice: Equatable, Sendable {
    public var usd: [String: Double]      // TCGplayer market: "normal", "holofoil", "reverse-holofoil", ...
    public var eur: [String: Double]      // Cardmarket: "trend", "avg30", "trend-holo", ...
    public var tcgdex: String?            // TCGdex card id, for a refresh
    public var tcgplayer: (Int64, Int64)? // TCGplayer (groupId, productId), for cards TCGdex doesn't price
    public var updated: String?           // set when refreshed in the app; else the book's date applies

    public init(usd: [String: Double], eur: [String: Double], tcgdex: String? = nil,
                tcgplayer: (Int64, Int64)? = nil, updated: String? = nil) {
        self.usd = usd; self.eur = eur; self.tcgdex = tcgdex; self.tcgplayer = tcgplayer; self.updated = updated
    }

    /** Default estimate when the variant isn't known: the plain printing, else the cheapest listed. */
    public var usdEstimate: Double? { usd["normal"] ?? usd["holofoil"] ?? usd.values.min() }

    public static func == (a: CardPrice, b: CardPrice) -> Bool {
        a.usd == b.usd && a.eur == b.eur && a.tcgdex == b.tcgdex && a.updated == b.updated &&
            a.tcgplayer?.0 == b.tcgplayer?.0 && a.tcgplayer?.1 == b.tcgplayer?.1
    }
}

public struct PriceBook: Equatable, Sendable {
    public var updated: String
    public var source: String
    public var cards: [String: CardPrice]

    public init(updated: String = "", source: String = "", cards: [String: CardPrice] = [:]) {
        self.updated = updated; self.source = source; self.cards = cards
    }

    public subscript(cardId: String) -> CardPrice? { cards[cardId] }

    /** This book with [newer]'s cards laid over it (prices from newer, ids kept from either). */
    public func overlay(_ newer: PriceBook) -> PriceBook {
        var out = self
        for (id, p) in newer.cards {
            let old = cards[id]
            out.cards[id] = CardPrice(usd: p.usd.isEmpty ? old?.usd ?? [:] : p.usd,
                                      eur: p.eur.isEmpty ? old?.eur ?? [:] : p.eur,
                                      tcgdex: p.tcgdex ?? old?.tcgdex, tcgplayer: p.tcgplayer ?? old?.tcgplayer,
                                      updated: p.updated)
        }
        return out
    }
}

/** prices.json format, shared by the bundled snapshot and the refreshed overlay. */
public enum PriceJson {
    public static func parse(_ data: Data) throws -> PriceBook {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = root["cards"] as? [String: [String: Any]] else { throw LoadError("bad prices.json") }
        var out: [String: CardPrice] = [:]
        out.reserveCapacity(cards.count)
        for (id, o) in cards {
            let tp = (o["tcgplayer"] as? [NSNumber]).flatMap { $0.count == 2 ? ($0[0].int64Value, $0[1].int64Value) : nil }
            out[id] = CardPrice(usd: doubles(o["usd"]), eur: doubles(o["eur"]),
                                tcgdex: (o["tcgdex"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                tcgplayer: tp,
                                updated: (o["updated"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return PriceBook(updated: root["updated"] as? String ?? "", source: root["source"] as? String ?? "", cards: out)
    }

    public static func write(_ book: PriceBook) throws -> Data {
        var cards: [String: Any] = [:]
        for (id, p) in book.cards {
            var o: [String: Any] = [:]
            if !p.usd.isEmpty { o["usd"] = p.usd }
            if !p.eur.isEmpty { o["eur"] = p.eur }
            if let t = p.tcgdex { o["tcgdex"] = t }
            if let t = p.tcgplayer { o["tcgplayer"] = [t.0, t.1] }
            if let u = p.updated { o["updated"] = u }
            cards[id] = o
        }
        return try JSONSerialization.data(withJSONObject: ["updated": book.updated, "source": book.source, "cards": cards])
    }

    private static func doubles(_ v: Any?) -> [String: Double] {
        (v as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
    }
}

/**
 * Fresh prices for a few cards (the user's collection), straight from the same
 * free sources fetch_prices.py uses: TCGdex per card, TCGCSV per TCGplayer group.
 * Needs [known] for each card's TCGdex id / TCGplayer product. Cards that fail keep
 * their old price. Kept polite: 4 requests at a time, and the app rate-limits
 * refreshes ([RefreshLimit]).
 */
public struct LivePriceSource: Sendable {
    public static let tcgdex = "https://api.tcgdex.net/v2/en"
    public static let tcgcsv = "https://tcgcsv.com/tcgplayer/3"
    static let eurFields = ["avg", "low", "trend", "avg7", "avg30"]

    let known: PriceBook
    let session: URLSession

    public init(known: PriceBook, session: URLSession = .shared) { self.known = known; self.session = session }

    public func load(_ ids: [String], stamp: String) async -> PriceBook {
        var jobs: [@Sendable () async -> [String: CardPrice]] = []
        for id in ids {
            guard let tid = known[id]?.tcgdex else { continue }
            jobs.append {
                guard let json = try? await getJson("\(Self.tcgdex)/cards/\(tid)") as? [String: Any],
                      let p = json["pricing"] as? [String: Any] else { return [:] }
                var price = compact(p)
                guard !price.usd.isEmpty || !price.eur.isEmpty else { return [:] }
                price.tcgdex = tid
                price.updated = stamp
                return [id: price]
            }
        }
        // TCGplayer-only cards: one request per group, not per card.
        let refs = ids.compactMap { id in known[id].flatMap { $0.tcgdex == nil ? $0.tcgplayer.map { (id, $0) } : nil } }
        for (group, members) in Dictionary(grouping: refs, by: { $0.1.0 }) {
            jobs.append {
                guard let json = try? await getJson("\(Self.tcgcsv)/\(group)/prices") as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else { return [:] }
                var byProduct: [Int64: [String: Double]] = [:]
                for r in results {
                    guard let v = positive(r["marketPrice"]) ?? positive(r["midPrice"]),
                          let product = (r["productId"] as? NSNumber)?.int64Value,
                          let sub = r["subTypeName"] as? String else { continue }
                    byProduct[product, default: [:]][sub.lowercased().replacingOccurrences(of: " ", with: "-")] = round2(v)
                }
                var out: [String: CardPrice] = [:]
                for (id, ref) in members {
                    if let usd = byProduct[ref.1] { out[id] = CardPrice(usd: usd, eur: [:], tcgplayer: ref, updated: stamp) }
                }
                return out
            }
        }

        var out: [String: CardPrice] = [:]
        await withTaskGroup(of: [String: CardPrice].self) { group in
            var next = 0
            for _ in 0..<min(4, jobs.count) { let j = jobs[next]; next += 1; group.addTask { await j() } }
            for await result in group {
                out.merge(result) { _, b in b }
                if next < jobs.count { let j = jobs[next]; next += 1; group.addTask { await j() } }
            }
        }
        return PriceBook(updated: stamp, source: "TCGdex / TCGCSV, refreshed in the app", cards: out)
    }

    /** Same fields as fetch_prices.compact(): TCGplayer market (else mid) per variant, Cardmarket EUR. */
    func compact(_ pricing: [String: Any]) -> CardPrice {
        var usd: [String: Double] = [:]
        for (variant, p) in pricing["tcgplayer"] as? [String: Any] ?? [:] {
            guard let p = p as? [String: Any], let v = positive(p["marketPrice"]) ?? positive(p["midPrice"]) else { continue }
            usd[variant] = round2(v)
        }
        var eur: [String: Double] = [:]
        let cm = pricing["cardmarket"] as? [String: Any] ?? [:]
        for f in Self.eurFields { for key in [f, "\(f)-holo"] { if let v = positive(cm[key]) { eur[key] = round2(v) } } }
        return CardPrice(usd: usd, eur: eur)
    }

    private func getJson(_ url: String) async throws -> Any {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.setValue("PullScan app (personal project)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LoadError("HTTP error for \(url)") }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func positive(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d.isFinite, d != 0 else { return nil }
        return d
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/**
 * At most [perHour] refreshes in any hour, and [cooldownMs] between two.
 * Pure: takes and returns the list of past refresh times (ms).
 */
public enum RefreshLimit {
    public static let perHour = 5
    public static let cooldownMs: Int64 = 5 * 60_000
    public static let hourMs: Int64 = 60 * 60_000

    /** ms to wait before the next refresh is allowed; 0 = allowed now. */
    public static func waitMs(_ history: [Int64], now: Int64) -> Int64 {
        let recent = history.filter { now - $0 < hourMs }.sorted()
        let cooldown = recent.last.map { $0 + cooldownMs - now } ?? 0
        let hourly = recent.count >= perHour ? recent[recent.count - perHour] + hourMs - now : 0
        return max(0, cooldown, hourly)
    }

    public static func left(_ history: [Int64], now: Int64) -> Int { perHour - history.filter { now - $0 < hourMs }.count }

    public static func record(_ history: [Int64], now: Int64) -> [Int64] { history.filter { now - $0 < hourMs } + [now] }
}
