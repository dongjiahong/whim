package com.whim.app.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.whim.app.ui.theme.WhimTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Custom Whim-styled Compose 24-hour wheel time picker with quick time presets.
 * Replaces the stock Android TimePickerDialog so the visual language matches Whim.
 */
@Composable
fun WhimTimePicker(
    hour: Int,
    minute: Int,
    onTimeChange: (hour: Int, minute: Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val c = WhimTheme.colors
    val presets = listOf(
        "08:30" to (8 to 30),
        "09:00" to (9 to 0),
        "12:30" to (12 to 30),
        "21:30" to (21 to 30),
        "22:30" to (22 to 30)
    )

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // Dual wheel container with center selection band
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(150.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(c.canvas)
                .border(0.8.dp, c.border, RoundedCornerShape(14.dp)),
            contentAlignment = Alignment.Center
        ) {
            // Subtle accent selection highlight band in the center
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .height(44.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(c.accent.copy(alpha = 0.13f))
                    .border(0.8.dp, c.accent.copy(alpha = 0.30f), RoundedCornerShape(10.dp))
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                NumberWheelColumn(
                    range = 0..23,
                    selectedValue = hour,
                    onValueSelected = { newHour ->
                        if (newHour != hour) onTimeChange(newHour, minute)
                    },
                    modifier = Modifier.width(88.dp)
                )

                Text(
                    text = ":",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    color = c.accent,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                )

                NumberWheelColumn(
                    range = 0..59,
                    selectedValue = minute,
                    onValueSelected = { newMinute ->
                        if (newMinute != minute) onTimeChange(hour, newMinute)
                    },
                    modifier = Modifier.width(88.dp)
                )
            }
        }

        // Quick preset time pills
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            presets.forEach { (label, pair) ->
                val active = hour == pair.first && minute == pair.second
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (active) c.accent else c.canvas)
                        .border(
                            0.7.dp,
                            if (active) c.accent else c.border,
                            RoundedCornerShape(8.dp)
                        )
                        .clickable { onTimeChange(pair.first, pair.second) }
                        .padding(vertical = 6.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = label,
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (active) Color.White else c.textSecondary,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NumberWheelColumn(
    range: IntRange,
    selectedValue: Int,
    onValueSelected: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val c = WhimTheme.colors
    val items = remember(range) { range.toList() }
    val itemHeightDp = 44.dp
    val initialIndex = (selectedValue - range.first).coerceIn(0, items.lastIndex)
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = initialIndex)
    val flingBehavior = rememberSnapFlingBehavior(lazyListState = listState)
    val scope = rememberCoroutineScope()

    val centerIndex by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val viewportCenter = (info.viewportStartOffset + info.viewportEndOffset) / 2
            info.visibleItemsInfo.minByOrNull { item ->
                kotlin.math.abs((item.offset + item.size / 2) - viewportCenter)
            }?.index ?: listState.firstVisibleItemIndex
        }
    }

    // Sync external preset taps into wheel scroll position
    LaunchedEffect(selectedValue) {
        val targetIndex = (selectedValue - range.first).coerceIn(0, items.lastIndex)
        if (!listState.isScrollInProgress && centerIndex != targetIndex) {
            listState.animateScrollToItem(targetIndex)
        }
    }

    // Emit value when scroll settles
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to centerIndex }
            .filter { (inProgress, _) -> !inProgress }
            .distinctUntilChanged()
            .collect { (_, idx) ->
                val value = items.getOrNull(idx) ?: return@collect
                onValueSelected(value)
            }
    }

    LazyColumn(
        state = listState,
        flingBehavior = flingBehavior,
        contentPadding = PaddingValues(vertical = 53.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier.height(150.dp)
    ) {
        items(items.size, key = { items[it] }) { idx ->
            val value = items[idx]
            val isCenter = idx == centerIndex
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(itemHeightDp)
                    .clickable {
                        scope.launch { listState.animateScrollToItem(idx) }
                        onValueSelected(value)
                    },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = String.format(Locale.getDefault(), "%02d", value),
                    fontSize = if (isCenter) 26.sp else 18.sp,
                    fontWeight = if (isCenter) FontWeight.Bold else FontWeight.Normal,
                    fontFamily = FontFamily.Monospace,
                    color = if (isCenter) c.accent else c.textMuted,
                    modifier = Modifier.alpha(if (isCenter) 1f else 0.55f)
                )
            }
        }
    }
}
