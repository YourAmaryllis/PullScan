import Foundation
import PullScanCore
import Observation
import os

let log = Logger(subsystem: "com.youramaryllis.pullscan", category: "PullScan")

/** Monotonic ms, for the card lock timers. */
func uptimeMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

/** UTC minute stamp, as in prices.json and backups: 2026-11-12T03:49Z. */
func utcStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
    return f.string(from: Date())
}

/** App settings, kept in UserDefaults. Same keys as the Android app's backup. */
struct Settings {
    private let d = UserDefaults.standard

    // Seconds on the same card before it's added automatically; 0 = off.
    var autoAddSeconds: Int {
        get { d.object(forKey: "autoAddSeconds") as? Int ?? 2 }
        nonmutating set { d.set(newValue, forKey: "autoAddSeconds") }
    }

    // Side of the screen for the check / cross buttons, for one-handed use.
    var buttonsLeft: Bool {
        get { d.bool(forKey: "buttonsLeft") }
        nonmutating set { d.set(newValue, forKey: "buttonsLeft") }
    }

    // Disclaimer version the user has acknowledged (0 = never); bump disclaimerVersion to show it again.
    var disclaimerAccepted: Int {
        get { d.integer(forKey: "disclaimerAccepted") }
        nonmutating set { d.set(newValue, forKey: "disclaimerAccepted") }
    }

    // Wall-clock ms of recent price refreshes (for the rate limit).
    var priceRefreshes: [Int64] {
        get { (d.array(forKey: "priceRefreshes") as? [NSNumber])?.map(\.int64Value) ?? [] }
        nonmutating set { d.set(newValue.map(NSNumber.init), forKey: "priceRefreshes") }
    }

    /** The user-facing settings, for a backup. */
    func export() -> [String: String] {
        ["autoAddSeconds": String(autoAddSeconds), "buttonsLeft": String(buttonsLeft)]
    }

    /** Applies settings from a backup; unknown keys (like Android's model choice) and bad values are ignored. */
    func `import`(_ values: [String: String]) {
        if let s = values["autoAddSeconds"].flatMap(Int.init), (0...60).contains(s) { autoAddSeconds = s }
        if let b = values["buttonsLeft"].flatMap(Bool.init) { buttonsLeft = b }
    }
}

/** The user's collection: card id -> count, kept in a JSON file in app storage. */
struct CollectionStore {
    private let file = URL.applicationSupportDirectory.appendingPathComponent("collection.json")

    func load() -> [String: Int] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    /** Overwrites the whole collection (add, import, reset). */
    func save(_ collection: [String: Int]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(collection).write(to: file, options: .atomic)
    }
}

/** Refreshed prices, kept in app storage and laid over the bundled snapshot. */
struct RefreshedPrices {
    private let file = URL.applicationSupportDirectory.appendingPathComponent("prices_refreshed.json")

    func load() -> PriceBook? { (try? Data(contentsOf: file)).flatMap { try? PriceJson.parse($0) } }

    func save(_ book: PriceBook) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PriceJson.write(book).write(to: file, options: .atomic)
    }
}

/** Everything the screens share: the model, card index, prices, collection and settings. */
@MainActor @Observable
final class AppModel {
    enum Phase { case loading, ready, failed(String) }

    var phase = Phase.loading
    private(set) var index: CardIndex?
    private(set) var embedder: Embedder?
    private(set) var byId: [String: Card] = [:]
    var prices = PriceBook()
    private(set) var collection: [String: Int] = [:]
    var autoAddSeconds: Int { didSet { settings.autoAddSeconds = autoAddSeconds } }
    var buttonsLeft: Bool { didSet { settings.buttonsLeft = buttonsLeft } }
    var disclaimerOk: Bool
    var refreshing = false

    let settings = Settings()
    private let store = CollectionStore()

    init() {
        autoAddSeconds = settings.autoAddSeconds
        buttonsLeft = settings.buttonsLeft
        disclaimerOk = settings.disclaimerAccepted >= Disclaimer.version
        collection = store.load()
    }

    var cardCount: Int { collection.values.reduce(0, +) }

    /** Model + 26k-card index take a moment; load off the main thread. */
    func load() async {
        guard index == nil else { return }
        do {
            let (idx, emb, book) = try await Task.detached(priority: .userInitiated) {
                let res = Bundle.main.resourceURL!
                let idx = try CardIndex.load(from: res)
                guard let url = Bundle.main.url(forResource: "Embedder", withExtension: "mlmodelc") else {
                    throw LoadError("Embedder model missing from the app (scripts/fetch_models.sh --ios)")
                }
                let emb = try Embedder(compiledModel: url)
                // Prices are optional: a missing or bad snapshot just shows no prices.
                // Prices refreshed in the app are laid over the bundled snapshot.
                let snapshot = (try? Data(contentsOf: res.appendingPathComponent("prices.json")))
                    .flatMap { try? PriceJson.parse($0) } ?? PriceBook()
                return (idx, emb, RefreshedPrices().load().map(snapshot.overlay) ?? snapshot)
            }.value
            index = idx
            embedder = emb
            byId = Dictionary(idx.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            prices = book
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func acceptDisclaimer() {
        settings.disclaimerAccepted = Disclaimer.version
        disclaimerOk = true
    }

    func change(_ id: String, by delta: Int) {
        let n = (collection[id] ?? 0) + delta
        collection[id] = n > 0 ? n : nil
        store.save(collection)
    }

    func replaceCollection(_ new: [String: Int]) {
        collection = new.filter { $0.value > 0 }
        store.save(collection)
    }

    func exportBackup() -> Data {
        Backup.export(collection: collection, cards: byId, settings: settings.export(), exportedAt: utcStamp())
    }

    func applyImportedSettings(_ values: [String: String]) {
        settings.import(values)
        autoAddSeconds = settings.autoAddSeconds
        buttonsLeft = settings.buttonsLeft
    }

    /** Fetches fresh prices for the collection, lays them over the snapshot and keeps them for next start. */
    func refreshPrices() async -> String {
        let ids = Array(collection.keys)
        refreshing = true
        settings.priceRefreshes = RefreshLimit.record(settings.priceRefreshes, now: Int64(Date().timeIntervalSince1970 * 1000))
        defer { refreshing = false }
        let fresh = await LivePriceSource(known: prices).load(ids, stamp: utcStamp())
        let saved = RefreshedPrices()
        var kept = (saved.load() ?? PriceBook(updated: fresh.updated, source: fresh.source)).overlay(fresh)
        kept.updated = fresh.updated
        saved.save(kept)
        prices = prices.overlay(fresh)
        log.info("prices refreshed \(fresh.cards.count)/\(ids.count)")
        return "Updated prices for \(fresh.cards.count) of \(ids.count) cards"
    }
}

enum Disclaimer {
    static let version = 1
    static let text = """
        Card identification is done by an AI model and can be wrong, especially between reprints \
        that share the same artwork. Prices are estimates from public market data (TCGplayer, \
        Cardmarket) and may be outdated or inaccurate. Always double-check the card and its value \
        before buying, selling or trading.

        PullScan is provided as is, without warranty. The authors are not responsible for any loss \
        from relying on its results.

        Unofficial fan project, not affiliated with Nintendo, Creatures, GAME FREAK or The Pokémon Company.
        """
}

/** Display helpers shared by the screens. */
enum Fmt {
    static func pct(_ score: Float) -> String { "\(Int(score * 100))%" }

    static func usd(_ v: Double) -> String {
        v < 100 ? String(format: "$%.2f", v) : "$" + v.formatted(.number.precision(.fractionLength(0)))
    }

    static func number(_ c: Card) -> String { "#\(c.number)" + (c.total.isEmpty ? "" : "/\(c.total)") }
}
