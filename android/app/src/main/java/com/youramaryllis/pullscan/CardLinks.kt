package com.youramaryllis.pullscan

import java.net.URLEncoder

/** A site that sells the card, with the prices we have for it (empty when the site has no price feed). */
data class Market(val site: String, val url: String, val prices: List<Pair<String, String>>)

/** Web links for a card: the official card database and the trading sites. Pure, so it's unit tested. */
object CardLinks {
    /** pokemon.com's card database, searched by name (its set codes don't map onto our set ids). */
    fun official(c: Card) = "https://www.pokemon.com/us/pokemon-tcg/pokemon-cards?cardName=${enc(c.name)}"

    /**
     * The trading sites, in the order shown. TCGplayer and Cardmarket prices come from the snapshot
     * or a live refresh (TCGdex / TCGCSV); eBay has no free price feed, so it's a sold-listings search.
     */
    fun markets(c: Card, p: CardPrice?): List<Market> = listOf(
        Market("TCGplayer", tcgplayer(c, p), p?.usd.orEmpty().entries.sortedBy { it.value }
            .map { (variant, v) -> variant.replace('-', ' ') to usd(v) }),
        Market("Cardmarket", cardmarket(c), EUR_SHOWN.mapNotNull { (key, label) ->
            p?.eur?.get(key)?.let { label to "€%.2f".format(it) }
        }),
        Market("eBay", ebaySold(c), emptyList()),
    )

    /** The product page when we know TCGplayer's product id, else a search by name. */
    fun tcgplayer(c: Card, p: CardPrice?): String = p?.tcgplayer?.second?.let { "https://www.tcgplayer.com/product/$it" }
        ?: "https://www.tcgplayer.com/search/pokemon/product?productLineName=pokemon&q=${enc(c.name)}"

    // Cardmarket's search matches product names only, so adding the set would find nothing.
    fun cardmarket(c: Card) = "https://www.cardmarket.com/en/Pokemon/Products/Search?searchString=${enc(c.name)}"

    fun ebaySold(c: Card): String {
        val number = if (c.total.isNotEmpty()) "${c.number}/${c.total}" else c.number
        return "https://www.ebay.com/sch/i.html?_nkw=${enc("pokemon ${c.name} ${c.set} $number")}&LH_Sold=1&LH_Complete=1"
    }

    fun usd(v: Double) = if (v < 100) "$%.2f".format(v) else "$%,.0f".format(v)

    private val EUR_SHOWN = listOf("trend" to "trend", "avg30" to "30-day avg", "low" to "lowest",
        "trend-holo" to "holo trend")

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
}
