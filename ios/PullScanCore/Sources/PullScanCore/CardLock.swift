import Foundation

/** The card currently held on screen. [score] is from the latest frame, [best] the highest since locking. */
public struct Locked: Equatable, Sendable {
    public var card: Card
    public var score: Float
    public var best: Float
    public var since: Int64      // ms (monotonic clock) the auto-add timer counts from
    public var added: Bool       // added to the collection during this lock (auto, check button or pick)
    public var others: [Match]   // other candidates in a fixed order: new ones are appended, never reordered
}

/**
 * Holds one recognised card on screen while the camera stays on it, so the
 * result doesn't flicker as the score wobbles around 50%. Same rules as the
 * Android CardLock:
 *
 * - Locks when the same card is on top for [frames] frames in a row at >= [lockAt].
 * - Stays locked while the score dips, until the top score is below [releaseBelow]
 *   for [frames] frames (the card left the frame), or a different card beats the
 *   locked card's best score for [frames] frames. Once the card has been added, only a
 *   card that isn't already a candidate can take over (a reprint can't undo the pick).
 * - Candidates (>= [releaseBelow]) keep the order they first appeared in; each shows its best score.
 * - Once the same card has been locked for [autoAddMs] (0 = off) and its best
 *   score reached [confident], [update] returns true, once per lock.
 */
public final class CardLock {
    // Cosine-similarity bands, from real use on a Galaxy Z Fold7: matches at or
    // above 0.60 were always the right card; non-cards score around 0.30.
    public static let lockAt: Float = 0.50        // below this, a new card isn't shown
    public static let confident: Float = 0.60     // 0.50-0.60 is shown as low confidence, never auto-added
    public static let releaseBelow: Float = 0.40  // the card has left the frame
    public static let frames = 2

    public var autoAddMs: Int64
    public private(set) var state: Locked?

    private var streakId: String?
    private var streak = 0
    private var lowFrames = 0

    public init(autoAddMs: Int64) { self.autoAddMs = autoAddMs }

    /** Feed one frame's matches (best first). Returns true when the locked card should be auto-added now. */
    @discardableResult
    public func update(_ matches: [Match], now: Int64) -> Bool {
        guard let top = matches.first else { return false }
        guard let locked = state else {
            if count(top.score >= Self.lockAt ? top.card.id : nil) >= Self.frames {
                lock(top, others: merge([], matches, exclude: top.card.id), now: now)
            }
            return false
        }

        if top.score < Self.releaseBelow {
            lowFrames += 1
            if lowFrames >= Self.frames { release() }
            return false
        }
        lowFrames = 0

        let known = locked.others.contains { $0.card.id == top.card.id }
        let challenger = top.card.id != locked.card.id && top.score > locked.best && !(locked.added && known)
            ? top.card.id : nil
        if count(challenger) >= Self.frames {
            let previous = [Match(locked.card, locked.best)] + locked.others
            lock(top, others: merge(previous, matches, exclude: top.card.id), now: now)
            return false
        }

        let mine = matches.first { $0.card.id == locked.card.id }
        var s = locked
        s.score = mine?.score ?? locked.score
        s.best = max(locked.best, mine?.score ?? 0)
        s.others = merge(locked.others, matches, exclude: locked.card.id)
        if !s.added && autoAddMs > 0 && s.best >= Self.confident && now - s.since >= autoAddMs {
            s.added = true
            state = s
            return true
        }
        state = s
        return false
    }

    /** The user added the locked card (check button): don't auto-add it again during this lock. */
    public func markAdded() {
        state?.added = true
    }

    /** The user picked [card] from the candidates: it becomes the locked card, already added. */
    public func choose(_ card: Card) {
        guard var s = state else { return }
        if card.id == s.card.id { markAdded(); return }
        let all = [Match(s.card, s.best)] + s.others
        s.score = all.first { $0.card.id == card.id }?.score ?? 0
        s.card = card
        s.added = true
        s.others = all.filter { $0.card.id != card.id }
        state = s
    }

    /** The pick sheet was cancelled: back to auto-detect, with the auto-add timer starting over. */
    public func restartTimer(now: Int64) {
        state?.since = now
    }

    /** ms left before auto-add, or nil when it won't happen during this lock. */
    public func remaining(now: Int64) -> Int64? {
        guard let s = state, !s.added, autoAddMs > 0, s.best >= Self.confident else { return nil }
        return max(0, autoAddMs - (now - s.since))
    }

    public func release() {
        state = nil
        streakId = nil
        streak = 0
        lowFrames = 0
    }

    private func lock(_ top: Match, others: [Match], now: Int64) {
        state = Locked(card: top.card, score: top.score, best: top.score, since: now, added: false, others: others)
        streakId = nil
        streak = 0
        lowFrames = 0
    }

    /** [current] in its order with best scores updated, then this frame's new candidates appended. */
    private func merge(_ current: [Match], _ frame: [Match], exclude: String) -> [Match] {
        let scores = Dictionary(frame.map { ($0.card.id, $0.score) }, uniquingKeysWith: max)
        let kept = current.filter { $0.card.id != exclude }.map { m in
            if let s = scores[m.card.id], s > m.score { return Match(m.card, s) }
            return m
        }
        let ids = Set(kept.map(\.card.id))
        let added = frame.filter { $0.card.id != exclude && !ids.contains($0.card.id) && $0.score >= Self.releaseBelow }
        return kept + added
    }

    /** Consecutive frames with the same non-nil [id]; nil breaks the streak. */
    private func count(_ id: String?) -> Int {
        if let id { streak = id == streakId ? streak + 1 : 1 } else { streak = 0 }
        streakId = id
        return streak
    }
}
