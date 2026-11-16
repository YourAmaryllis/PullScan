@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package com.youramaryllis.pullscan

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.InputChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Collection screen pieces: search, sort and filter sheets, set and card rows, card details.
// The screen itself (state, price refresh) is MainActivity.CollectionScreen.

@Composable
internal fun Heading(text: String) = Text(text, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)

@Composable
internal fun Note(text: String) = Text(text, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)

internal fun usd(v: Double) = CardLinks.usd(v)

@Composable
internal fun SearchField(text: String, onText: (String) -> Unit) {
    val focus = LocalFocusManager.current
    OutlinedTextField(
        value = text, onValueChange = onText, singleLine = true,
        placeholder = { Text("Search name, set or #number") },
        trailingIcon = if (text.isEmpty()) null else ({ TextButton(onClick = { onText("") }) { Text("✕") } }),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
        modifier = Modifier.fillMaxWidth(),
    )
}

/** "Sets | Cards" toggle on the left, Sort and Filter on the right (the filter shows how many are on). */
@Composable
internal fun CollectionToolbar(
    bySet: Boolean?,   // null: inside a set, no toggle
    onBySet: (Boolean) -> Unit,
    filterCount: Int,
    onSort: () -> Unit,
    onFilter: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (bySet != null) SingleChoiceSegmentedButtonRow(Modifier.widthIn(max = 220.dp)) {
            listOf(true to "Sets", false to "Cards").forEachIndexed { i, (value, label) ->
                SegmentedButton(selected = bySet == value, onClick = { onBySet(value) },
                    shape = SegmentedButtonDefaults.itemShape(i, 2), icon = {}) { Text(label) }
            }
        }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onSort) { Text("⇅ Sort") }
        TextButton(onClick = onFilter) { Text(if (filterCount > 0) "Filter ($filterCount)" else "Filter") }
    }
}

/** The filters in use as removable chips, so they're visible without opening the sheet. */
@Composable
internal fun ActiveFilters(filter: CollectionFilter, onFilter: (CollectionFilter) -> Unit) {
    if (filter.active == 0) return
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (filter.minUsd != null || filter.maxUsd != null) {
            Removable(priceRangeLabel(filter.minUsd, filter.maxUsd)) { onFilter(filter.copy(minUsd = null, maxUsd = null)) }
        }
        filter.rarities.sorted().forEach { r -> Removable(r) { onFilter(filter.copy(rarities = filter.rarities - r)) } }
        if (filter.duplicatesOnly) Removable("Duplicates") { onFilter(filter.copy(duplicatesOnly = false)) }
    }
}

@Composable
private fun Removable(label: String, onRemove: () -> Unit) {
    InputChip(selected = true, onClick = onRemove, label = { Text(label) }, trailingIcon = { Text("✕") })
}

private fun priceRangeLabel(min: Double?, max: Double?) = when {
    min != null && max != null -> "${usd(min)}–${usd(max)}"
    min != null -> "${usd(min)}+"
    max != null -> "under ${usd(max)}"
    else -> "any price"
}

@Composable
internal fun SortSheet(sort: CollectionSort, bySet: Boolean, onSort: (CollectionSort) -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            Heading(if (bySet) "Sort sets" else "Sort cards")
            if (bySet) Note("Cards inside a set use the same order.")
            Spacer(Modifier.height(8.dp))
            CollectionSort.entries.forEach { s ->
                Row(Modifier.fillMaxWidth().clickable { onSort(s); onDismiss() }.padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = s == sort, onClick = null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (bySet) s.setLabel else s.label, color = Color.White, fontSize = 15.sp)
                }
            }
        }
    }
}

/** Filters apply as they change; the button shows how many cards are left and closes the sheet. */
@Composable
internal fun FilterSheet(
    filter: CollectionFilter,
    rarities: List<String>,
    matches: Int,
    onFilter: (CollectionFilter) -> Unit,
    onDismiss: () -> Unit,
) {
    var minText by remember { mutableStateOf(filter.minUsd?.let(::plain).orEmpty()) }
    var maxText by remember { mutableStateOf(filter.maxUsd?.let(::plain).orEmpty()) }
    fun setRange(min: String, max: String) {
        minText = min; maxText = max
        onFilter(filter.copy(minUsd = min.toDoubleOrNull(), maxUsd = max.toDoubleOrNull()))
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Heading("Filter")
                Spacer(Modifier.weight(1f))
                TextButton(enabled = filter.active > 0, onClick = {
                    minText = ""; maxText = ""
                    onFilter(CollectionFilter(text = filter.text))
                }) { Text("Clear all") }
            }

            Spacer(Modifier.height(8.dp))
            Text("Price per card (USD)", color = Color.White, fontSize = 15.sp)
            Note("Cards without a price are hidden while a price range is set.")
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
                PriceField("Min", minText, Modifier.weight(1f)) { setRange(it, maxText) }
                Text("  –  ", color = Color.White)
                PriceField("Max", maxText, Modifier.weight(1f)) { setRange(minText, it) }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                PRICE_PRESETS.forEach { (min, max) ->
                    val selected = filter.minUsd == min && filter.maxUsd == max
                    FilterChip(selected = selected, label = { Text(priceRangeLabel(min, max)) }, onClick = {
                        if (selected) setRange("", "") else setRange(min?.let(::plain).orEmpty(), max?.let(::plain).orEmpty())
                    })
                }
            }

            Spacer(Modifier.height(16.dp))
            Text("Rarity", color = Color.White, fontSize = 15.sp)
            Note("Only rarities you own are listed. None selected = all.")
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                rarities.forEach { r ->
                    val on = r in filter.rarities
                    FilterChip(selected = on, label = { Text(r) }, onClick = {
                        onFilter(filter.copy(rarities = if (on) filter.rarities - r else filter.rarities + r))
                    })
                }
            }

            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Duplicates only", color = Color.White, fontSize = 15.sp)
                    Note("Cards you have 2 or more of, e.g. to trade.")
                }
                Switch(checked = filter.duplicatesOnly, onCheckedChange = { onFilter(filter.copy(duplicatesOnly = it)) })
            }

            Spacer(Modifier.height(16.dp))
            Button(onClick = onDismiss, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                Text(if (matches == 1) "Show 1 card" else "Show $matches cards")
            }
        }
    }
}

@Composable
private fun PriceField(label: String, text: String, modifier: Modifier, onText: (String) -> Unit) {
    OutlinedTextField(
        value = text, singleLine = true, label = { Text(label) }, prefix = { Text("$") }, modifier = modifier,
        onValueChange = { v -> if (v.isEmpty() || v.matches(Regex("""\d{0,6}(\.\d{0,2})?"""))) onText(v) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
    )
}

private fun plain(v: Double) = if (v == Math.floor(v)) v.toLong().toString() else "%.2f".format(v)

private val PRICE_PRESETS = listOf(null to 1.0, 1.0 to 10.0, 10.0 to 50.0, 50.0 to null)

/** One set: name, series and year, how much of it you own, and its value. */
@Composable
internal fun SetRow(g: SetGroup, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(g.name, color = Color.White, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Note(listOf(g.series, g.released.take(4)).filter { it.isNotEmpty() }.distinct().joinToString(" · "))
            }
            Column(horizontalAlignment = Alignment.End) {
                if (g.value > 0) Text(usd(g.value), color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp)
                Note("${g.copies} ${if (g.copies == 1) "copy" else "copies"}")
            }
            Text("  ›", color = Color.White.copy(alpha = 0.5f), fontSize = 20.sp)
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
            LinearProgressIndicator(progress = { g.completion }, modifier = Modifier.weight(1f).height(4.dp),
                color = MainActivity.GREEN, trackColor = Color(0x33FFFFFF), drawStopIndicator = {})
            Spacer(Modifier.width(8.dp))
            Note("${g.cards.size} / ${g.inDatabase}")
        }
    }
}

/** One card: name, set and number, rarity; copies and value on the right. Tap for details. */
@Composable
internal fun CardRow(o: Owned, showSet: Boolean, onClick: () -> Unit) {
    val c = o.card
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(c.name, color = Color.White, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Note(listOfNotNull(if (showSet) "${c.set} #${c.number}" else "#${c.number}", c.rarity.ifEmpty { null })
                .joinToString(" · "))
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(o.usd?.let { usd(it * o.count) } ?: "—", color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp)
            Note(if (o.count > 1 && o.usd != null) "×${o.count} · ${usd(o.usd)} ea" else "×${o.count}")
        }
        Text("  ›", color = Color.White.copy(alpha = 0.5f), fontSize = 20.sp)
    }
    HorizontalDivider(color = Color(0x1FFFFFFF))
}

enum class LivePrice { LOADING, LIVE, UNAVAILABLE, NO_SOURCE }

/** Full card page: facts, copies, prices per site with links. No card picture: the artwork isn't ours to show. */
@Composable
internal fun CardDetails(
    card: Card,
    count: Int,
    price: CardPrice?,
    snapshotDate: String,
    live: LivePrice,
    onChange: (Int) -> Unit,
    onOpen: (String) -> Unit,
    onBack: () -> Unit,
) {
    Column(Modifier.verticalScroll(rememberScrollState()).navigationBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("‹ Back") }
        }
        Spacer(Modifier.height(8.dp))
        Text(card.name, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Text("${card.set} · #${card.number}${if (card.total.isNotEmpty()) "/${card.total}" else ""}",
            color = Color.White, fontSize = 15.sp)
        Note(listOf(card.rarity, card.series, card.released.take(4)).filter { it.isNotEmpty() }.distinct().joinToString(" · "))
        if (card.artist.isNotEmpty()) Note("Illustrated by ${card.artist}")

        Spacer(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("In collection", color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
            OutlinedButton(onClick = { onChange(-1) }, enabled = count > 0) { Text("−", fontSize = 18.sp) }
            Text("$count", color = Color.White, fontSize = 18.sp, modifier = Modifier.padding(horizontal = 16.dp))
            OutlinedButton(onClick = { onChange(1) }) { Text("+", fontSize = 18.sp) }
        }
        price?.usdEstimate?.let { Note("≈ ${usd(it)} each" + if (count > 1) " · ${usd(it * count)} for $count" else "") }

        Spacer(Modifier.height(20.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Heading("Prices")
            Spacer(Modifier.width(8.dp))
            if (live == LivePrice.LOADING) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
        }
        val asOf = (price?.updated ?: snapshotDate).replace('T', ' ').replace("Z", " UTC")
        Note(when (live) {
            LivePrice.LOADING -> "Getting live prices…"
            LivePrice.LIVE -> "Live, updated $asOf"
            LivePrice.UNAVAILABLE -> "Live prices not available right now; showing prices from $asOf"
            LivePrice.NO_SOURCE -> "No live price source for this card; showing prices from $asOf"
        })
        CardLinks.markets(card, price).forEach { m -> MarketRow(m, onOpen) }

        Spacer(Modifier.height(16.dp))
        OutlinedButton(onClick = { onOpen(CardLinks.official(card)) }, modifier = Modifier.fillMaxWidth()) {
            Text("Official card database (pokemon.com) ›")
        }
        Spacer(Modifier.height(12.dp))
        Note("Prices are estimates from public market data and may be out of date. Check the listing before " +
            "buying, selling or trading.")
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun MarketRow(m: Market, onOpen: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().clickable { onOpen(m.url) }.padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(m.site, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Text("Open ›", color = MainActivity.GREEN, fontSize = 14.sp)
        }
        if (m.prices.isEmpty()) Note(if (m.site == "eBay") "Recently sold listings" else "No price listed")
        m.prices.forEach { (label, value) ->
            Row {
                Text(label, color = Color.White.copy(alpha = 0.75f), fontSize = 13.sp, modifier = Modifier.weight(1f))
                Text(value, color = Color.White, fontSize = 13.sp)
            }
        }
    }
    HorizontalDivider(color = Color(0x1FFFFFFF))
}
