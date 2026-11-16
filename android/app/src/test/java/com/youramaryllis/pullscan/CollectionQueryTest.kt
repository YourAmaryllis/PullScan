package com.youramaryllis.pullscan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionQueryTest {
    private fun card(id: String, name: String, set: String, released: String, rarity: String = "Common") =
        Card(id, name, set, "", id.substringAfterLast('-'), "", rarity, released, "")

    private val charizard = card("base1-4", "Charizard", "Base", "1999/01/09", "Rare Holo")
    private val pikachu = card("base1-58", "Pikachu", "Base", "1999/01/09")
    private val pikachu2 = card("sv1-10", "Pikachu", "Scarlet & Violet", "2023/03/31", "")
    private val eevee = card("sv1-2", "Eevee", "Scarlet & Violet", "2023/03/31")
    private val all = listOf(charizard, pikachu, pikachu2, eevee)
    private val prices = mapOf("base1-4" to 900.0, "base1-58" to 2.0, "sv1-2" to 0.5)   // sv1-10 unpriced
    private val owned = CollectionQuery.owned(mapOf("base1-4" to 1, "base1-58" to 3, "sv1-10" to 1, "sv1-2" to 2),
        all.associateBy { it.id }) { prices[it] }

    private fun ids(f: CollectionFilter = CollectionFilter(), s: CollectionSort = CollectionSort.RELEASE_OLD) =
        CollectionQuery.cards(owned, f, s).map { it.card.id }

    @Test fun sorts() {
        assertEquals(listOf("base1-4", "base1-58", "sv1-2", "sv1-10"), ids())        // number padded: 4 < 58, 2 < 10
        assertEquals(listOf("sv1-2", "sv1-10", "base1-4", "base1-58"), ids(s = CollectionSort.RELEASE_NEW))
        assertEquals(listOf("base1-4", "base1-58", "sv1-2", "sv1-10"), ids(s = CollectionSort.VALUE_DESC))
        assertEquals(listOf("sv1-2", "base1-58", "base1-4", "sv1-10"), ids(s = CollectionSort.VALUE_ASC))  // unpriced last
        assertEquals(listOf("base1-4", "sv1-2", "base1-58", "sv1-10"), ids(s = CollectionSort.NAME))
        assertEquals("base1-58", ids(s = CollectionSort.COUNT).first())
    }

    @Test fun filters() {
        assertEquals(listOf("base1-58", "sv1-10"), ids(CollectionFilter(text = "pika")))
        assertEquals(listOf("sv1-2", "sv1-10"), ids(CollectionFilter(text = "scarlet")))
        assertEquals(listOf("base1-4"), ids(CollectionFilter(text = "#4")))
        assertEquals(listOf("base1-58", "sv1-2"), ids(CollectionFilter(minUsd = 0.5, maxUsd = 10.0)))   // unit price
        assertEquals(listOf("base1-4"), ids(CollectionFilter(minUsd = 100.0)))
        assertEquals(listOf("sv1-10"), ids(CollectionFilter(rarities = setOf(CollectionFilter.NO_RARITY))))
        assertEquals(listOf("base1-58", "sv1-2"), ids(CollectionFilter(duplicatesOnly = true)))
        assertEquals(3, CollectionFilter(text = "x", maxUsd = 1.0, rarities = setOf("Common"), duplicatesOnly = true).active)
    }

    @Test fun groupsBySet() {
        val sizes = CollectionQuery.setSizes(all + card("base1-1", "Alakazam", "Base", "1999/01/09"))
        val sets = CollectionQuery.sets(owned, sizes, CollectionFilter(), CollectionSort.VALUE_DESC)
        assertEquals(listOf("base1", "sv1"), sets.map { it.setId })
        assertEquals(906.0, sets[0].value, 1e-9)
        assertEquals(4, sets[0].copies)
        assertEquals(2f / 3, sets[0].completion, 1e-6f)
        val filtered = CollectionQuery.sets(owned, sizes, CollectionFilter(text = "eevee"), CollectionSort.NAME)
        assertEquals(listOf("sv1"), filtered.map { it.setId })
        assertEquals(listOf("sv1-2"), filtered[0].cards.map { it.card.id })
    }

    @Test fun setIds() {
        assertEquals("base1", charizard.setId)
        assertEquals("tcg1533", Card("tcg1533-98168", "Pikachu", "Prize Pack", "", "1", "", "", "", "").setId)
    }

    @Test fun links() {
        val price = CardPrice(mapOf("holofoil" to 922.32), mapOf("trend" to 402.26), tcgplayer = 0L to 42382L)
        val markets = CardLinks.markets(charizard, price)
        assertEquals(listOf("TCGplayer", "Cardmarket", "eBay"), markets.map { it.site })
        assertEquals("https://www.tcgplayer.com/product/42382", markets[0].url)
        assertEquals(listOf("holofoil" to "$922"), markets[0].prices)
        assertEquals(listOf("trend" to "€402.26"), markets[1].prices)
        assertTrue(CardLinks.tcgplayer(pikachu2, null).endsWith("q=Pikachu"))
        assertTrue(CardLinks.cardmarket(pikachu2).endsWith("searchString=Pikachu"))
        assertTrue(CardLinks.ebaySold(pikachu2).contains("Scarlet%20%26%20Violet%2010"))
        assertTrue(CardLinks.official(card("x-1", "Mr. Mime", "", "")).endsWith("cardName=Mr.%20Mime"))
    }
}
