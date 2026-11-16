package com.youramaryllis.pullscan

/** A collection entry: the card, how many copies, and its estimated unit price (USD) if known. */
data class Owned(val card: Card, val count: Int, val usd: Double?) {
    val value: Double get() = (usd ?: 0.0) * count
}

/** The owned cards of one set, plus how many cards that set has in the app's card list. */
data class SetGroup(val setId: String, val cards: List<Owned>, val inDatabase: Int) {
    val name: String get() = cards.first().card.set
    val series: String get() = cards.first().card.series
    val released: String get() = cards.first().card.released
    val copies: Int get() = cards.sumOf { it.count }
    val value: Double get() = cards.sumOf { it.value }
    val completion: Float get() = if (inDatabase == 0) 0f else cards.size.toFloat() / inDatabase
}

enum class CollectionSort(val label: String, val setLabel: String = label) {
    VALUE_DESC("Value: high to low"),
    VALUE_ASC("Value: low to high"),
    NAME("Name: A to Z"),
    RELEASE_OLD("Set & number: oldest first", "Release: oldest first"),
    RELEASE_NEW("Set & number: newest first", "Release: newest first"),
    COUNT("Copies: most first", "Completion: most first"),
}

/** Filters for the collection list; [text] is the search box, the rest is the filter sheet. */
data class CollectionFilter(
    val text: String = "",
    val minUsd: Double? = null,   // unit price; cards without a price drop out when either bound is set
    val maxUsd: Double? = null,
    val rarities: Set<String> = emptySet(),
    val duplicatesOnly: Boolean = false,
) {
    /** Number of filter-sheet filters in use (not counting the search box), for the badge. */
    val active: Int
        get() = (if (minUsd != null || maxUsd != null) 1 else 0) + (if (rarities.isNotEmpty()) 1 else 0) +
            (if (duplicatesOnly) 1 else 0)

    fun matches(o: Owned): Boolean {
        val c = o.card
        val q = text.trim()
        if (q.isNotEmpty() && !(c.name.contains(q, true) || c.set.contains(q, true) ||
                c.number.equals(q.removePrefix("#"), true))) return false
        if (minUsd != null || maxUsd != null) {
            val p = o.usd ?: return false
            if (minUsd != null && p < minUsd) return false
            if (maxUsd != null && p > maxUsd) return false
        }
        if (rarities.isNotEmpty() && c.rarity.ifEmpty { NO_RARITY } !in rarities) return false
        return !duplicatesOnly || o.count > 1
    }

    companion object {
        const val NO_RARITY = "No rarity"
    }
}

/** Pure sorting / filtering / grouping for the collection screen (no Android, so it's unit tested). */
object CollectionQuery {
    fun owned(collection: Map<String, Int>, byId: Map<String, Card>, usd: (String) -> Double?): List<Owned> =
        collection.mapNotNull { (id, n) -> byId[id]?.let { Owned(it, n, usd(id)) } }

    fun cards(owned: List<Owned>, filter: CollectionFilter, sort: CollectionSort): List<Owned> =
        owned.filter(filter::matches).sortedWith(cardOrder(sort))

    /** Sets that still have a card after [filter]; each set's cards are sorted by [sort]. */
    fun sets(owned: List<Owned>, setSizes: Map<String, Int>, filter: CollectionFilter, sort: CollectionSort): List<SetGroup> {
        val groups = cards(owned, filter, sort).groupBy { it.card.setId }
            .map { (setId, cards) -> SetGroup(setId, cards, setSizes[setId] ?: cards.size) }
        val byRelease = compareBy<SetGroup>({ it.released }, { it.name })
        return groups.sortedWith(when (sort) {
            CollectionSort.VALUE_DESC -> compareByDescending<SetGroup> { it.value }.then(byRelease)
            CollectionSort.VALUE_ASC -> compareBy<SetGroup> { it.value }.then(byRelease)
            CollectionSort.NAME -> compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }
            CollectionSort.RELEASE_OLD -> byRelease
            CollectionSort.RELEASE_NEW -> compareByDescending<SetGroup> { it.released }.then(byRelease)
            CollectionSort.COUNT -> compareByDescending<SetGroup> { it.completion }.then(byRelease)
        })
    }

    /** Cards per set in the whole card list, for "12 / 102" completion. */
    fun setSizes(cards: Collection<Card>): Map<String, Int> = cards.groupingBy { it.setId }.eachCount()

    /** Release date, set, then the number with its digits padded so 2 sorts before 10. */
    private val bySetNumber = compareBy<Owned>({ it.card.released }, { it.card.set }, { it.card.number.padStart(4, '0') })

    private fun cardOrder(sort: CollectionSort): Comparator<Owned> = when (sort) {
        // Unpriced cards go last both ways: they're unknown, not free.
        CollectionSort.VALUE_DESC -> compareBy<Owned> { it.usd == null }.thenByDescending { it.value }.then(bySetNumber)
        CollectionSort.VALUE_ASC -> compareBy<Owned> { it.usd == null }.thenBy { it.value }.then(bySetNumber)
        CollectionSort.NAME -> compareBy<Owned, String>(String.CASE_INSENSITIVE_ORDER) { it.card.name }.then(bySetNumber)
        CollectionSort.RELEASE_OLD -> bySetNumber
        // Newest set first, but still #1, #2, ... inside a set.
        CollectionSort.RELEASE_NEW -> compareByDescending<Owned> { it.card.released }.then(bySetNumber)
        CollectionSort.COUNT -> compareByDescending<Owned> { it.count }.then(bySetNumber)
    }
}
