import AVFoundation
import PullScanCore
import Observation
import SwiftUI

/** Scan-screen state: the camera's latest result and the locked card. */
@MainActor @Observable
final class ScanModel {
    private(set) var result: ScanResult?
    private(set) var locked: Locked?
    var picking = false
    var toast: String?
    var addedCount = 0   // drives the haptic
    var cameraMissing = false

    let camera: Camera
    private let lock: CardLock
    private let app: AppModel

    init(app: AppModel, embedder: Embedder, index: CardIndex) {
        self.app = app
        camera = Camera(embedder: embedder, index: index)
        lock = CardLock(autoAddMs: Int64(app.autoAddSeconds) * 1000)
        cameraMissing = !camera.configure()
        camera.onResult = { [weak self] in self?.frame($0) }
    }

    func appear() {
        camera.paused = picking
        camera.start()
    }

    // Stop analysing (and auto-adding) when the scan screen is left for the collection or settings.
    func disappear() {
        camera.paused = true
        camera.stop()
    }

    func remaining() -> Int64? { lock.remaining(now: uptimeMs()) }

    private func frame(_ r: ScanResult) {
        if camera.paused { return }   // sheet opened while this frame ran
        result = r
        lock.autoAddMs = Int64(app.autoAddSeconds) * 1000
        let before = lock.state
        let autoAdd = lock.update(r.matches, now: uptimeMs())
        locked = lock.state
        logLock(before, lock.state, r, autoAdd)
        if autoAdd, let c = locked?.card { app.change(c.id, by: 1); added(c, " automatically") }
    }

    func check() {
        guard let c = locked?.card else { return }
        app.change(c.id, by: 1)
        lock.markAdded()
        locked = lock.state
        added(c, "")
        log.info("added by check \(c.id)")
    }

    func openPicker() {
        guard locked != nil else { return }
        picking = true
        camera.paused = true
        log.info("picker opened for \(self.locked?.card.id ?? "-")")
    }

    func closePicker() {
        picking = false
        if locked?.added == false { lock.restartTimer(now: uptimeMs()) }
        locked = lock.state
        camera.paused = false
        log.info("picker cancelled")
    }

    func pick(_ card: Card) {
        guard let l = locked else { return }
        if !(l.added && l.card.id == card.id) {
            // Picked after an auto-add of a different card: swap it, don't keep both.
            if l.added { app.change(l.card.id, by: -1) }
            app.change(card.id, by: 1)
            added(card, l.added ? " instead of \(l.card.name)" : "")
        }
        log.info("picked \(card.id)\(l.added && l.card.id != card.id ? " replacing \(l.card.id)" : "")")
        lock.choose(card)
        locked = lock.state
        picking = false
        camera.paused = false
    }

    private func added(_ card: Card, _ how: String) {
        addedCount += 1
        toast = "Added \(card.name) (\(card.set))\(how)"
    }

    /** One log line per lock change, so a phone test can be read back from Console. */
    private func logLock(_ before: Locked?, _ after: Locked?, _ r: ScanResult, _ autoAdd: Bool) {
        let top = r.matches.first
        if autoAdd {
            log.info("auto-added \(after?.card.id ?? "-") best \(Fmt.pct(after?.best ?? 0))")
        } else if let after, after.card.id != before?.card.id {
            log.info("lock \(after.card.id) (\(after.card.name)) at \(Fmt.pct(after.score))\(before.map { " replacing \($0.card.id) best \(Fmt.pct($0.best))" } ?? "")")
        } else if after == nil, let before {
            log.info("release \(before.card.id) best \(Fmt.pct(before.best)), top now \(Fmt.pct(top?.score ?? 0))")
        }
    }
}

struct ScanView: View {
    @Environment(AppModel.self) private var app
    let scan: ScanModel
    var onCollection: () -> Void
    var onSettings: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if scan.cameraMissing {
                    Color.black
                    Text("No camera available on this device.").foregroundStyle(.white.opacity(0.7))
                } else {
                    CameraPreview(session: scan.camera.session)
                }
                GuideOverlay(added: scan.locked?.added == true)
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomPanel
                }
                if scan.picking, let l = scan.locked {
                    PickerSheet(locked: l, buttonsLeft: app.buttonsLeft, onPick: scan.pick, onCancel: scan.closePicker)
                }
            }
            .onAppear { scan.camera.viewSize = geo.size }
            .onChange(of: geo.size) { scan.camera.viewSize = geo.size }
        }
        .ignoresSafeArea()
        .onAppear { scan.appear() }
        .onDisappear { scan.disappear() }
        .sensoryFeedback(.success, trigger: scan.addedCount)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PullScan").font(.headline).foregroundStyle(.white)
                Spacer()
                Button("Collection (\(app.cardCount))", action: onCollection)
                Button("Settings", action: onSettings)
            }
            if let r = scan.result {
                HStack(spacing: 8) {
                    if let img = r.input {
                        Image(decorative: img, scale: 1).resizable().frame(width: 40, height: 55)
                    }
                    Text("model input · \(r.millis) ms · top \(Fmt.pct(r.matches.first?.score ?? 0))")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
    }

    private var bottomPanel: some View {
        HStack(alignment: .center, spacing: 14) {
            if app.buttonsLeft { buttons }
            VStack(alignment: .leading, spacing: 2) { details }
                .frame(maxWidth: .infinity, alignment: .leading)
            if !app.buttonsLeft { buttons }
        }
        .padding(16)
        .padding(.bottom, 24)
        .background(Color(red: 0.06, green: 0.08, blue: 0.09).opacity(0.9),
                    in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
    }

    private var buttons: some View {
        let l = scan.locked
        return VStack(spacing: 14) {
            RoundButton(symbol: "checkmark", color: .holoGreen, enabled: l != nil && l?.added == false, action: scan.check)
                .accessibilityLabel("Add card")
            RoundButton(symbol: "xmark", color: .holoRed, enabled: l != nil, action: scan.openPicker)
                .accessibilityLabel("Pick another match")
        }
    }

    @ViewBuilder private var details: some View {
        if let l = scan.locked {
            if l.added { AddedBanner() }
            CardSummary(card: l.card, label: lockLabel(l), ok: l.best >= CardLock.confident)
            PriceLine(price: app.prices[l.card.id], bookDate: app.prices.updated)
            // Fixed order (see CardLock): the list only grows, it doesn't reshuffle.
            if !l.others.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Note("Also possible (✕ to pick)")
                    ForEach(l.others.prefix(3), id: \.card.id) { m in
                        Text("\(m.card.name) · \(m.card.set) #\(m.card.number) · \(Fmt.pct(m.score))")
                            .font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .padding(.top, 6)
                .contentShape(Rectangle())
                .onTapGesture(perform: scan.openPicker)
            }
        } else {
            Text("Hold a card inside the frame, right side up").foregroundStyle(.white)
            if let top = scan.result?.matches.first { Note("no card recognised (best \(Fmt.pct(top.score)))") }
            // The model only knows upright cards; an upside-down one scores like a random object.
            Note("Cards are only recognised upright, not upside down or sideways")
            Note("✓ adds the card · ✕ picks another match")
        }
        if let t = scan.toast { Text(t).font(.caption).foregroundStyle(Color.holoGreen).padding(.top, 6) }
    }

    private func lockLabel(_ l: Locked) -> String {
        var s = "match \(Fmt.pct(l.score))"
        if l.added { return s }
        if l.best < CardLock.confident { s += " · low confidence, check the card" }
        else if let ms = scan.remaining() { s += String(format: " · adding in %.1f s", Double(ms) / 1000) }
        return s
    }
}

/** List of the detected card and its candidates; the camera is paused while it's open. */
struct PickerSheet: View {
    @Environment(AppModel.self) private var app
    let locked: Locked
    let buttonsLeft: Bool
    let onPick: (Card) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.8).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 8) {
                Text("Which card is it?").font(.title3.bold()).foregroundStyle(.white)
                Note(locked.added ? "\(locked.card.name) was added; picking another card replaces it."
                     : "Tap the right card to add it. Cancel goes back to auto-detect.")
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach([Match(locked.card, locked.best)] + locked.others, id: \.card.id) { m in
                            option(m)
                        }
                    }
                }
                .frame(maxHeight: 420)
                HStack {
                    if !buttonsLeft { Spacer() }
                    Button("Cancel", action: onCancel)
                        .font(.body).buttonStyle(.bordered).controlSize(.large)
                    if buttonsLeft { Spacer() }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
            .background(Color(red: 0.10, green: 0.12, blue: 0.14),
                        in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func option(_ m: Match) -> some View {
        let first = m.card.id == locked.card.id
        let c = m.card
        let meta = ([c.set + " · " + Fmt.number(c)] + [c.rarity, String(c.released.prefix(4))].filter { !$0.isEmpty })
            .joined(separator: " · ")
        let status = first ? (locked.added ? " · added" : " · detected") : ""
        let price = app.prices[c.id]?.usdEstimate.map { " · ≈ \(Fmt.usd($0))" } ?? ""
        return Button { onPick(c) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.headline).foregroundStyle(.white)
                Text(meta).font(.footnote).foregroundStyle(.white.opacity(0.8))
                Text("match \(Fmt.pct(m.score))\(status)\(price)")
                    .font(.caption).foregroundStyle(first ? Color.holoGreen : .white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(first ? Color.holoGreen : .white.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GuideOverlay: View {
    let added: Bool

    var body: some View {
        Canvas { ctx, size in
            let g = Path(roundedRect: guideRect(size), cornerRadius: 12)
            var shade = Path(CGRect(origin: .zero, size: size))
            shade.addPath(g)
            ctx.fill(shade, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            // The outline turns green once the card in it has been added.
            ctx.stroke(g, with: .color(added ? .holoGreen : .white), lineWidth: added ? 5 : 2)
        }
        .allowsHitTesting(false)
    }
}

struct RoundButton: View {
    let symbol: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(enabled ? .black : Color(white: 0.47))
                .frame(width: 68, height: 68)
                .background(enabled ? color : Color(white: 0.23), in: Circle())
        }
        .disabled(!enabled)
    }
}

struct AddedBanner: View {
    var body: some View {
        Label("Card added", systemImage: "checkmark")
            .font(.subheadline.bold()).foregroundStyle(.black)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoGreen, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 6)
    }
}

struct CardSummary: View {
    let card: Card
    let label: String
    let ok: Bool

    var body: some View {
        Text(card.name).font(.title2.bold()).foregroundStyle(.white)
        Text("\(card.set) · \(Fmt.number(card))").font(.subheadline).foregroundStyle(.white)
        Text([card.rarity, String(card.released.prefix(4)), card.series].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.footnote).foregroundStyle(.white.opacity(0.75))
        Text(label).font(.caption).foregroundStyle(ok ? Color.holoGreen : Color.holoAmber)
    }
}

/** Estimated price per variant, e.g. "≈ $0.27 normal · $0.43 reverse-holofoil · €0.08 trend". */
struct PriceLine: View {
    let price: CardPrice?
    let bookDate: String

    var body: some View {
        let text: String
        if let p = price {
            let parts = p.usd.sorted { $0.value < $1.value }.map { "\(Fmt.usd($0.value)) \($0.key)" } +
                (p.eur["trend"].map { [String(format: "€%.2f trend", $0)] } ?? [])
            text = "≈ " + parts.joined(separator: " · ")
        } else {
            text = "no price data"
        }
        let date = price?.updated.map { " · refreshed \($0.prefix(10))" }
            ?? (bookDate.isEmpty ? "" : " · prices \(bookDate.prefix(10))")
        return Text(text + date).font(.caption).foregroundStyle(.white.opacity(0.75))
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.white.opacity(0.7)) }
}

extension Color {
    static let holoGreen = Color(red: 0x8B / 255, green: 0xD1 / 255, blue: 0x7C / 255)
    static let holoAmber = Color(red: 0xE0 / 255, green: 0xB0 / 255, blue: 0x50 / 255)
    static let holoRed = Color(red: 0xE5 / 255, green: 0x73 / 255, blue: 0x73 / 255)
}
