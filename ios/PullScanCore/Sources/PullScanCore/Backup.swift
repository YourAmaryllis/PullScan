import Foundation

/** Minimal RFC 4180 CSV: comma separated, fields quoted when they contain a comma, quote or newline. */
public enum Csv {
    public static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(quote).joined(separator: ",") + "\r\n" }.joined()
    }

    private static func quote(_ f: String) -> String {
        f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
    }

    public static func read(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if quoted && ch == "\"" && next == "\"" { field.unicodeScalars.append("\""); i += 1 }
            else if ch == "\"" { quoted.toggle() }
            else if quoted { field.unicodeScalars.append(ch) }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r" {
                if ch == "\r" && next == "\n" { i += 1 }
                row.append(field); field = ""
                rows.append(row); row = []
            } else { field.unicodeScalars.append(ch) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /** Rows as header -> value maps; the header row is matched case-insensitively. */
    public static func records(_ text: String) -> [[String: String]] {
        let rows = read(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let first = rows.first else { return [] }
        let header = first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return rows.dropFirst().map { r in
            Dictionary(header.indices.map { (header[$0], $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : "") },
                       uniquingKeysWith: { a, _ in a })
        }
    }
}

/**
 * Export / import of the collection, the same format as the Android app, so a
 * collection moves between phones (either platform) without any account or server.
 * A zip of plain CSV files that also opens in a spreadsheet:
 *
 *   collection.csv   card_id,count,name,set,number,rarity   (only card_id and count are read back)
 *   settings.csv     key,value
 *   info.csv         key,value   (format version, export time)
 */
public enum Backup {
    public static let format = "1"

    public struct Contents: Equatable {
        public let collection: [String: Int]
        public let settings: [String: String]
    }

    public static func export(collection: [String: Int], cards: [String: Card], settings: [String: String],
                              exportedAt: String) -> Data {
        let coll = [["card_id", "count", "name", "set", "number", "rarity"]] +
            collection.sorted { $0.key < $1.key }.map { id, n in
                let c = cards[id]
                return [id, String(n), c?.name ?? "", c?.set ?? "", c?.number ?? "", c?.rarity ?? ""]
            }
        let sett = [["key", "value"]] + settings.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        let info = [["key", "value"], ["app", "PullScan"], ["format", format], ["exported_at", exportedAt],
                    ["cards", String(collection.values.reduce(0, +))]]
        return Zip.write([("collection.csv", coll), ("settings.csv", sett), ("info.csv", info)]
            .map { ($0.0, Data(Csv.write($0.1).utf8)) })
    }

    /** Reads a backup zip, or a bare collection.csv. */
    public static func `import`(_ data: Data) throws -> Contents {
        var files: [String: String] = [:]
        let zipped = try Zip.read(data)
        for (name, body) in zipped ?? [:] {
            files[(name.split(separator: "/").last.map(String.init) ?? name).lowercased()] = String(decoding: body, as: UTF8.self)
        }
        guard let collText = files["collection.csv"] ?? (zipped == nil ? String(decoding: data, as: UTF8.self) : nil) else {
            throw LoadError("no collection.csv in the backup")
        }
        let records = Csv.records(collText)
        if let first = records.first, first["card_id"] == nil { throw LoadError("collection.csv has no card_id column") }
        var collection: [String: Int] = [:]
        for r in records {
            let id = r["card_id"] ?? ""
            let n = Int(r["count"] ?? "") ?? 1
            if !id.isEmpty && n > 0 { collection[id, default: 0] += n }
        }
        var settings: [String: String] = [:]
        for r in files["settings.csv"].map(Csv.records) ?? [] {
            if let k = r["key"], !k.isEmpty { settings[k] = r["value"] ?? "" }
        }
        return Contents(collection: collection, settings: settings)
    }
}
