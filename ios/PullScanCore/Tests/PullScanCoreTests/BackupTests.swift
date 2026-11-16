@testable import PullScanCore
import XCTest

final class BackupTests: XCTestCase {
    func testCsvRoundTripsQuotesAndCommas() {
        let rows = [["card_id", "name"], ["sv1-1", "Pikachu, \"the\" mouse"], ["x", "line\nbreak"]]
        XCTAssertEqual(Csv.read(Csv.write(rows)), rows)
    }

    func testZipRoundTrip() throws {
        let card = Card(id: "mcd26-3", name: "Pikachu, Jr.", set: "McDonald's 2026", number: "3", total: "15", rarity: "Promo")
        let zip = Backup.export(collection: ["mcd26-3": 2, "base1-4": 1], cards: [card.id: card],
                                settings: ["autoAddSeconds": "3"], exportedAt: "2026-11-11T20:00Z")
        let back = try Backup.import(zip)
        XCTAssertEqual(back.collection, ["mcd26-3": 2, "base1-4": 1])
        XCTAssertEqual(back.settings["autoAddSeconds"], "3")
    }

    func testZipChecksum() {
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    /** Made by java.util.zip.ZipOutputStream, as the Android app exports: deflated, with data descriptors. */
    func testImportsAndroidBackup() throws {
        let android = "UEsDBBQACAgIAGdNbF0AAAAAAAAAAAAAAAAOAAAAY29sbGVjdGlvbi5jc3YNy0EKgzAQRuG94B2Cm25+S43iAWoXIhSkFyhjMmCoSWBiFu3pm93jg2dI7NtZmJjDiUCekbhE9hsLhMSd37raKHHXDugw7YV+ZcK9GAa8SFjN8Yh15Y3VY9tDo1ndh8yeoRa5NniaRwx02EtS+qZH9Fgl+nL8AVBLBwhSkji5dwAAAH4AAABQSwMEFAAICAgAZ01sXQAAAAAAAAAAAAAAAAwAAABzZXR0aW5ncy5jc3bLTq3UKUvMKU3l5UosLcl3TEkJTk3Oz0sp1jHm5UoqLSnJzyv2SU0r0SkpAqnJzU9JzdFJzU1KTUlJLdLLzCux0MvPy6vg5QIAUEsHCG/+7zZJAAAASQAAAFBLAQIUABQACAgIAGdNbF1Skji5dwAAAH4AAAAOAAAAAAAAAAAAAAAAAAAAAABjb2xsZWN0aW9uLmNzdlBLAQIUABQACAgIAGdNbF1v/u82SQAAAEkAAAAMAAAAAAAAAAAAAAAAALMAAABzZXR0aW5ncy5jc3ZQSwUGAAAAAAIAAgB2AAAANgEAAAAA"
        let back = try Backup.import(Data(base64Encoded: android)!)
        XCTAssertEqual(back.collection, ["base1-4": 1, "mcd26-3": 2])
        XCTAssertEqual(back.settings["buttonsLeft"], "true")
    }

    func testBareCsvImports() throws {
        let csv = "\u{FEFF}Card_ID,Count\r\nsv1-1,3\nsv1-1,1\nsv1-2,\n"
        XCTAssertEqual(try Backup.import(Data(csv.utf8)).collection, ["sv1-1": 4, "sv1-2": 1])
    }

    func testRefreshLimit() {
        let m: Int64 = 60_000
        XCTAssertEqual(RefreshLimit.waitMs([], now: 0), 0)
        XCTAssertEqual(RefreshLimit.waitMs([0], now: 2 * m), 3 * m)                    // 5 min cooldown
        let five: [Int64] = [0, 6 * m, 12 * m, 18 * m, 24 * m]
        XCTAssertEqual(RefreshLimit.waitMs(five, now: 30 * m), 30 * m)                 // 5 in the hour: until 60 min
        XCTAssertEqual(RefreshLimit.waitMs(five, now: 60 * m), 0)
        XCTAssertEqual(RefreshLimit.left(five, now: 30 * m), 0)
    }

    func testPriceJsonRoundTripAndOverlay() throws {
        let book = PriceBook(updated: "2026-11-12", source: "test", cards: [
            "a": CardPrice(usd: ["normal": 1.5], eur: ["trend": 1.2], tcgdex: "a"),
            "b": CardPrice(usd: ["holofoil": 9], eur: [:], tcgplayer: (100, 200)),
        ])
        XCTAssertEqual(try PriceJson.parse(PriceJson.write(book)), book)
        let fresh = PriceBook(updated: "2026-11-13", cards: ["b": CardPrice(usd: ["holofoil": 10], eur: [:], updated: "2026-11-13")])
        let merged = book.overlay(fresh)
        XCTAssertEqual(merged["b"]?.usdEstimate, 10)
        XCTAssertEqual(merged["b"]?.tcgplayer?.1, 200)   // ids kept from the older book
        XCTAssertEqual(merged["a"], book["a"])
    }
}
