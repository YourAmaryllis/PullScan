import PullScanCore
import SwiftUI

struct CollectionView: View {
    @Environment(AppModel.self) private var app
    var onClose: () -> Void
    @State private var message: String?

    var body: some View {
        let rows = app.collection.compactMap { id, n in app.byId[id].map { ($0, n) } }
            .sorted { ($0.0.released, $0.0.set, pad($0.0.number)) < ($1.0.released, $1.0.set, pad($1.0.number)) }
        let total = app.collection.reduce(0.0) { $0 + (app.prices[$1.key]?.usdEstimate ?? 0) * Double($1.value) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collection · \(app.cardCount) cards").font(.title3.bold()).foregroundStyle(.white)
                    Note("≈ \(Fmt.usd(total)) estimated\(app.prices.updated.isEmpty ? "" : " · prices \(app.prices.updated.prefix(10))")")
                    Note("Estimates only: check current prices before buying, selling or trading.")
                }
                Spacer()
                Button("Scan", action: onClose)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in refreshRow(now: ctx.date) }
            if let message { Text(message).font(.caption).foregroundStyle(Color.holoGreen) }
            if rows.isEmpty {
                Text("Nothing yet — scan a card and tap ✓.").foregroundStyle(.white.opacity(0.7)).padding(.top, 8)
            }
            List(rows, id: \.0.id) { c, n in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.name).foregroundStyle(.white)
                        Note("\(c.set) #\(c.number) · \(c.rarity)")
                    }
                    Spacer()
                    if let p = app.prices[c.id]?.usdEstimate {
                        Text(Fmt.usd(p * Double(n))).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    }
                    Button("−") { app.change(c.id, by: -1) }.buttonStyle(.borderless).padding(.horizontal, 6)
                    Text("\(n)").foregroundStyle(.white).monospacedDigit()
                    Button("+") { app.change(c.id, by: 1) }.buttonStyle(.borderless).padding(.horizontal, 6)
                }
                .listRowBackground(Color.black)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(16)
    }

    private func refreshRow(now: Date) -> some View {
        let history = app.settings.priceRefreshes
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let wait = RefreshLimit.waitMs(history, now: ms)
        let left = RefreshLimit.left(history, now: ms)
        return HStack(spacing: 10) {
            Button(app.refreshing ? "Refreshing…" : "Refresh prices") {
                Task { message = await app.refreshPrices() }
            }
            .buttonStyle(.bordered)
            .disabled(app.refreshing || wait > 0 || app.collection.isEmpty)
            Note(app.refreshing ? "\(app.collection.count) cards"
                 : wait > 0 ? String(format: "next in %d:%02d · %d left this hour", wait / 60_000, (wait / 1000) % 60, left)
                 : "\(left) of \(RefreshLimit.perHour) left this hour")
        }
    }

    private func pad(_ s: String) -> String { String(repeating: "0", count: max(0, 4 - s.count)) + s }
}
