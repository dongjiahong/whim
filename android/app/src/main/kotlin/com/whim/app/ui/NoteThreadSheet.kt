package com.whim.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimNote
import com.whim.app.ui.theme.WhimTheme
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Bottom sheet modal for viewing and appending chronological follow-up replies (Thread) to a note.
 */
@Composable
fun NoteThreadSheet(
    parentNote: WhimNote,
    onDismiss: () -> Unit,
    onThreadChanged: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val scope = rememberCoroutineScope()

    var replies by remember(parentNote.id) { mutableStateOf<List<WhimNote>>(emptyList()) }
    var loading by remember(parentNote.id) { mutableStateOf(true) }
    var draft by remember(parentNote.id) { mutableStateOf("") }
    var sending by remember(parentNote.id) { mutableStateOf(false) }

    suspend fun reloadReplies() {
        loading = true
        replies = runCatching { WhimCoreBridge.listReplies(parentNote.id) }.getOrDefault(emptyList())
        loading = false
    }

    LaunchedEffect(parentNote.id) {
        reloadReplies()
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0x88000000))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss
                )
                .imePadding(),
            contentAlignment = Alignment.BottomCenter
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(0.76f)
                    .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .background(c.canvas)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {}
                    )
                    .navigationBarsPadding()
            ) {
                // Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("追记", style = t.title, color = c.textPrimary)
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(c.accent.copy(alpha = 0.16f))
                                .padding(horizontal = 8.dp, vertical = 2.dp)
                        ) {
                            Text(
                                "${replies.size}",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = c.accent
                            )
                        }
                    }
                    Icon(
                        Icons.Rounded.Close,
                        contentDescription = "关闭",
                        tint = c.textSecondary,
                        modifier = Modifier
                            .size(22.dp)
                            .clickable(onClick = onDismiss)
                    )
                }

                // Parent note context card
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(c.card)
                        .border(0.8.dp, c.border, RoundedCornerShape(12.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = formatThreadTime(parentNote.createdAt),
                        style = t.meta,
                        color = c.textMuted
                    )
                    Text(
                        text = parentNote.content.trim().ifEmpty { "[图片笔记]" },
                        style = t.body,
                        color = c.textPrimary,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                Spacer(Modifier.height(10.dp))

                // Replies list
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (loading) {
                        item {
                            Text(
                                "加载中...",
                                style = t.meta,
                                color = c.textMuted,
                                modifier = Modifier.padding(vertical = 18.dp)
                            )
                        }
                    } else if (replies.isEmpty()) {
                        item {
                            Text(
                                "还没有追记，在下方记下对这条闪念的延伸思考吧。",
                                style = t.meta,
                                color = c.textMuted,
                                modifier = Modifier.padding(vertical = 22.dp)
                            )
                        }
                    } else {
                        items(replies, key = { it.id }) { reply ->
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(11.dp))
                                    .background(c.card)
                                    .border(0.7.dp, c.border, RoundedCornerShape(11.dp))
                                    .padding(horizontal = 14.dp, vertical = 11.dp),
                                verticalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = formatThreadTime(reply.createdAt),
                                        style = t.meta,
                                        color = c.textMuted
                                    )
                                    Icon(
                                        Icons.Rounded.DeleteOutline,
                                        contentDescription = "删除追记",
                                        tint = c.textMuted,
                                        modifier = Modifier
                                            .size(16.dp)
                                            .clickable {
                                                scope.launch {
                                                    runCatching {
                                                        WhimCoreBridge.updateNote(id = reply.id, deleted = true)
                                                    }
                                                    reloadReplies()
                                                    onThreadChanged()
                                                }
                                            }
                                    )
                                }
                                Text(
                                    text = reply.content.trim(),
                                    style = t.body,
                                    color = c.textPrimary
                                )
                            }
                        }
                    }
                    item { Spacer(Modifier.height(8.dp)) }
                }

                // Composer bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(c.card)
                        .border(0.7.dp, c.border)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.canvas)
                            .padding(horizontal = 12.dp, vertical = 10.dp)
                    ) {
                        BasicTextField(
                            value = draft,
                            onValueChange = { draft = it },
                            textStyle = t.body.copy(color = c.textPrimary),
                            cursorBrush = SolidColor(c.accent),
                            maxLines = 4,
                            modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (draft.isEmpty()) {
                                    Text("写一条追记...", style = t.body, color = c.textMuted)
                                }
                                inner()
                            }
                        )
                    }

                    val canSend = draft.isNotBlank() && !sending
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .background(if (canSend) c.accent else c.accent.copy(alpha = 0.4f))
                            .clickable(enabled = canSend) {
                                val text = draft.trim()
                                sending = true
                                scope.launch {
                                    runCatching {
                                        WhimCoreBridge.createReply(parentNote.id, text)
                                    }.onSuccess {
                                        draft = ""
                                        reloadReplies()
                                        onThreadChanged()
                                    }
                                    sending = false
                                }
                            }
                            .padding(horizontal = 13.dp, vertical = 9.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.AutoMirrored.Rounded.Send,
                            contentDescription = "发送追记",
                            tint = Color.White,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
            }
        }
    }
}

private fun formatThreadTime(epochMs: Long): String {
    if (epochMs <= 0L) return ""
    val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())
    return fmt.format(Date(epochMs))
}
