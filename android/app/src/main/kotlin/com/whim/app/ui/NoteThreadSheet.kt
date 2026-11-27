package com.whim.app.ui

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.AsyncImage
import coil.request.ImageRequest
import coil.size.Precision
import com.whim.app.MobileCardBlock
import com.whim.app.MobileCardParseCache
import com.whim.app.MobileImageBoundsCache
import com.whim.app.MobileMarkdownChunksView
import com.whim.app.core.WhimAttachment
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimNote
import com.whim.app.ui.theme.WhimTheme
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Bottom sheet modal for viewing and appending chronological follow-up replies (Thread) to a note,
 * with full inline image support matching the main note composer and renderer.
 */
@Composable
fun NoteThreadSheet(
    parentNote: WhimNote,
    onTapImage: (List<String>, Int) -> Unit,
    onDismiss: () -> Unit,
    onThreadChanged: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var replies by remember(parentNote.id) { mutableStateOf<List<WhimNote>>(emptyList()) }
    var loading by remember(parentNote.id) { mutableStateOf(true) }
    var draftValue by remember(parentNote.id) { mutableStateOf(TextFieldValue("")) }
    val draftAttachments = remember(parentNote.id) { mutableStateListOf<WhimAttachment>() }
    var sending by remember(parentNote.id) { mutableStateOf(false) }

    suspend fun reloadReplies() {
        loading = true
        replies = runCatching { WhimCoreBridge.listReplies(parentNote.id) }.getOrDefault(emptyList())
        loading = false
    }

    fun insertAtCursor(snippet: String) {
        val sel = draftValue.selection
        val start = sel.min.coerceIn(0, draftValue.text.length)
        val end = sel.max.coerceIn(start, draftValue.text.length)
        val updated = draftValue.text.substring(0, start) + snippet + draftValue.text.substring(end)
        draftValue = TextFieldValue(text = updated, selection = TextRange(start + snippet.length))
    }

    fun removeAttachmentToken(sha256: String) {
        val tokenRegex = Regex("\\n?!\\[[^\\]]*\\]\\(whim://blob/$sha256\\)\\n?")
        val cleaned = tokenRegex.replace(draftValue.text, "\n").trim('\n')
        val pos = draftValue.selection.end.coerceIn(0, cleaned.length)
        draftValue = TextFieldValue(text = cleaned, selection = TextRange(pos))
    }

    fun ingestUri(uri: Uri) {
        scope.launch {
            runCatching {
                val mime = context.contentResolver.getType(uri) ?: "image/png"
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@runCatching
                val saved = WhimCoreBridge.saveBlob(bytes, mime)
                if (draftAttachments.none { it.sha256 == saved.sha256 }) {
                    draftAttachments.add(
                        WhimAttachment(
                            sha256 = saved.sha256,
                            mime = saved.mime,
                            sizeBytes = saved.sizeBytes,
                            localPath = saved.localPath
                        )
                    )
                }
                val curStart = draftValue.selection.min.coerceIn(0, draftValue.text.length)
                val needLeadingNL = curStart > 0 && draftValue.text[curStart - 1] != '\n'
                val prefix = if (needLeadingNL) "\n" else ""
                insertAtCursor("${prefix}![image](whim://blob/${saved.sha256})\n")
            }
        }
    }

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri -> uri?.let { ingestUri(it) } }

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
                    .fillMaxHeight(0.82f)
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

                // Scrollable Parent Note + Replies Timeline
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    item(key = "__parent__") {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(c.card)
                                .border(0.8.dp, c.accent.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
                                .padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text(
                                text = formatThreadTime(parentNote.createdAt),
                                style = t.meta,
                                color = c.textMuted
                            )
                            ThreadRichBody(
                                note = parentNote,
                                onTapImage = onTapImage
                            )
                        }
                    }

                    if (loading) {
                        item(key = "__loading__") {
                            Text(
                                "加载中...",
                                style = t.meta,
                                color = c.textMuted,
                                modifier = Modifier.padding(vertical = 18.dp)
                            )
                        }
                    } else if (replies.isEmpty()) {
                        item(key = "__empty__") {
                            Text(
                                "还没有追记，在下方记下延伸思考或插入图片吧。",
                                style = t.meta,
                                color = c.textMuted,
                                modifier = Modifier.padding(vertical = 22.dp)
                            )
                        }
                    } else {
                        itemsIndexed(replies, key = { _, it -> it.id }) { idx, reply ->
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(11.dp))
                                    .background(c.card)
                                    .border(0.7.dp, c.border, RoundedCornerShape(11.dp))
                                    .padding(horizontal = 14.dp, vertical = 11.dp),
                                verticalArrangement = Arrangement.spacedBy(7.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(7.dp)
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(4.dp))
                                                .background(c.accent.copy(alpha = 0.16f))
                                                .padding(horizontal = 6.dp, vertical = 2.dp)
                                        ) {
                                            Text(
                                                "追记 #${idx + 1}",
                                                fontSize = 10.5.sp,
                                                fontWeight = FontWeight.SemiBold,
                                                color = c.accent
                                            )
                                        }
                                        Text(
                                            text = formatThreadTime(reply.createdAt),
                                            style = t.meta,
                                            color = c.textMuted
                                        )
                                    }
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
                                ThreadRichBody(
                                    note = reply,
                                    onTapImage = onTapImage
                                )
                            }
                        }
                    }
                    item(key = "__spacer__") { Spacer(Modifier.height(8.dp)) }
                }

                // Composer bar with inline image attachments
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(c.card)
                        .border(0.7.dp, c.border)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (draftAttachments.isNotEmpty()) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(draftAttachments, key = { it.sha256 }) { att ->
                                Box(
                                    modifier = Modifier
                                        .size(56.dp)
                                        .clip(RoundedCornerShape(7.dp))
                                ) {
                                    AsyncImage(
                                        model = File(att.localPath),
                                        contentDescription = "追记图片",
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize()
                                    )
                                    Box(
                                        modifier = Modifier
                                            .align(Alignment.TopEnd)
                                            .padding(2.dp)
                                            .size(16.dp)
                                            .clip(CircleShape)
                                            .background(Color(0xAA000000))
                                            .clickable {
                                                draftAttachments.remove(att)
                                                removeAttachmentToken(att.sha256)
                                            },
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Icon(
                                            Icons.Rounded.Close,
                                            contentDescription = "移除图片",
                                            tint = Color.White,
                                            modifier = Modifier.size(10.dp)
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
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
                                value = draftValue,
                                onValueChange = { draftValue = it },
                                textStyle = t.body.copy(color = c.textPrimary),
                                cursorBrush = SolidColor(c.accent),
                                maxLines = 4,
                                modifier = Modifier.fillMaxWidth(),
                                decorationBox = { inner ->
                                    if (draftValue.text.isEmpty()) {
                                        Text("写一条追记...", style = t.body, color = c.textMuted)
                                    }
                                    inner()
                                }
                            )
                        }

                        Icon(
                            Icons.Rounded.Image,
                            contentDescription = "选图",
                            tint = c.textSecondary,
                            modifier = Modifier
                                .size(22.dp)
                                .clickable {
                                    photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                                }
                        )

                        Icon(
                            Icons.Rounded.ContentPaste,
                            contentDescription = "贴图",
                            tint = c.textSecondary,
                            modifier = Modifier
                                .size(20.dp)
                                .clickable {
                                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                    val clip = cm.primaryClip
                                    if (clip != null && clip.itemCount > 0) {
                                        val item = clip.getItemAt(0)
                                        when {
                                            item.uri != null -> ingestUri(item.uri)
                                            !item.text.isNullOrBlank() -> insertAtCursor(item.text.toString())
                                        }
                                    }
                                }
                        )

                        val canSend = (draftValue.text.isNotBlank() || draftAttachments.isNotEmpty()) && !sending
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(9.dp))
                                .background(if (canSend) c.accent else c.accent.copy(alpha = 0.4f))
                                .clickable(enabled = canSend) {
                                    val text = draftValue.text.trim()
                                    val atts = draftAttachments.toList()
                                    sending = true
                                    scope.launch {
                                        runCatching {
                                            WhimCoreBridge.createReply(parentNote.id, text, atts)
                                        }.onSuccess {
                                            draftValue = TextFieldValue("")
                                            draftAttachments.clear()
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
}

@Composable
private fun ThreadRichBody(
    note: WhimNote,
    onTapImage: (List<String>, Int) -> Unit
) {
    val c = WhimTheme.colors
    val context = LocalContext.current
    val parsed = remember(note.id, note.updatedAt, c.textPrimary, note.attachments.size) {
        MobileCardParseCache.getOrParse(
            note = note,
            primary = c.textPrimary,
            secondary = c.textSecondary,
            muted = c.textMuted,
            accent = c.accent,
            codeBg = c.tagBg,
            codeFg = c.tagText
        )
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        parsed.blocks.forEach { block ->
            when (block) {
                is MobileCardBlock.TextBlock -> MobileMarkdownChunksView(chunks = block.chunks)
                is MobileCardBlock.ImageBlock -> {
                    val ratio = remember(block.path) { MobileImageBoundsCache.aspectRatio(block.path) }
                    val req = remember(block.path) {
                        ImageRequest.Builder(context)
                            .data(File(block.path))
                            .size(960, 960)
                            .precision(Precision.INEXACT)
                            .crossfade(160)
                            .build()
                    }
                    AsyncImage(
                        model = req,
                        contentDescription = "内联图片",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 260.dp)
                            .aspectRatio(ratio)
                            .clip(RoundedCornerShape(8.dp))
                            .background(c.canvas)
                            .clickable {
                                val idx = parsed.allImagePaths.indexOf(block.path).coerceAtLeast(0)
                                onTapImage(parsed.allImagePaths, idx)
                            }
                    )
                }
            }
        }

        if (parsed.trailing.isNotEmpty()) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(parsed.trailing, key = { it.sha256 }) { att ->
                    val req = remember(att.localPath) {
                        ImageRequest.Builder(context)
                            .data(File(att.localPath))
                            .size(320, 320)
                            .precision(Precision.INEXACT)
                            .crossfade(160)
                            .build()
                    }
                    AsyncImage(
                        model = req,
                        contentDescription = "图片附件",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(96.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(c.canvas)
                            .clickable {
                                val idx = parsed.allImagePaths.indexOf(att.localPath).coerceAtLeast(0)
                                onTapImage(parsed.allImagePaths, idx)
                            }
                    )
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
