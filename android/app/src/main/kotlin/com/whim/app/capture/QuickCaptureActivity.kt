package com.whim.app.capture

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.FormatListBulleted
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.CheckBox
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.FormatListNumbered
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Tag
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.whim.app.core.WhimAttachment
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimTagNode
import com.whim.app.sync.SyncWorker
import com.whim.app.ui.theme.WhimTheme
import com.whim.app.ui.theme.WhimThemeProvider
import kotlinx.coroutines.launch
import java.io.File

/**
 * Flomo-style instant floating capture & edit sheet launched from Quick Settings Tile,
 * Home Screen Widget, Share Sheet, main FAB, or card Edit action.
 */
class QuickCaptureActivity : ComponentActivity() {
    companion object {
        const val EXTRA_EDIT_NOTE_ID = "edit_note_id"
        const val EXTRA_EDIT_CONTENT = "edit_content"
        const val EXTRA_EDIT_ATTACHMENTS_JSON = "edit_attachments_json"
        private const val DRAFT_PREFS = "whim_capture_draft"
        private const val KEY_DRAFT_TEXT = "draft_text"
        private const val KEY_DRAFT_ATTACHMENTS = "draft_attachments"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WhimCoreBridge.ensureInit(this)

        val editNoteId = intent?.getStringExtra(EXTRA_EDIT_NOTE_ID)
        val editContent = intent?.getStringExtra(EXTRA_EDIT_CONTENT)
        val editAttachmentsJson = intent?.getStringExtra(EXTRA_EDIT_ATTACHMENTS_JSON)

        val sharedText = editContent ?: if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
        } else ""

        val sharedImageUri: Uri? = if (editNoteId == null && intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("image/") == true) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
        } else null

        val initialAttachments = if (editNoteId != null) {
            WhimCoreBridge.decodeAttachments(editAttachmentsJson)
        } else {
            emptyList()
        }

        setContent {
            val prefs = remember { getSharedPreferences("whim_ui_prefs", Context.MODE_PRIVATE) }
            val mode = prefs.getString("theme_mode", "system") ?: "system"
            val sysDark = androidx.compose.foundation.isSystemInDarkTheme()
            val useDark = when (mode) {
                "light" -> false
                "dark" -> true
                else -> sysDark
            }
            WhimThemeProvider(darkTheme = useDark) {
                FlomoQuickCaptureSheet(
                    editNoteId = editNoteId,
                    initialText = sharedText,
                    initialAttachments = initialAttachments,
                    initialImageUri = sharedImageUri,
                    onDismiss = { finish() },
                    onSaved = {
                        WhimWidgetProvider.refreshAll(this)
                        SyncWorker.enqueueImmediate(this)
                        finish()
                    }
                )
            }
        }
    }
}

private val quickTagVisualRegex = Regex("(^|[\\s(\\[{（【「『，。、；：！？,.;:!?])(#[^\\s#,.;:!?，。、；：！？)\\]}）】」』]+)")

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FlomoQuickCaptureSheet(
    editNoteId: String? = null,
    initialText: String = "",
    initialAttachments: List<WhimAttachment> = emptyList(),
    initialImageUri: Uri? = null,
    onDismiss: () -> Unit,
    onSaved: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }
    val draftPrefs = remember { context.getSharedPreferences("whim_capture_draft", Context.MODE_PRIVATE) }

    val restoredDraft = remember(editNoteId, initialText, initialImageUri) {
        if (editNoteId == null && initialText.isEmpty() && initialImageUri == null) {
            val dText = draftPrefs.getString("draft_text", "").orEmpty()
            val dAtts = WhimCoreBridge.decodeAttachments(draftPrefs.getString("draft_attachments", null))
            if (dText.isNotEmpty() || dAtts.isNotEmpty()) dText to dAtts else null
        } else null
    }

    val startText = restoredDraft?.first ?: initialText
    val startAtts = restoredDraft?.second ?: initialAttachments

    var textValue by remember {
        mutableStateOf(TextFieldValue(text = startText, selection = TextRange(startText.length)))
    }
    val attachments = remember { mutableStateListOf<WhimAttachment>().apply { addAll(startAtts) } }
    var draftRestoredBanner by remember { mutableStateOf(restoredDraft != null) }
    var allTags by remember { mutableStateOf<List<String>>(emptyList()) }
    var saving by remember { mutableStateOf(false) }

    val text = textValue.text
    val canSubmit = !saving && (text.isNotBlank() || attachments.isNotEmpty())

    fun clearDraft() {
        draftPrefs.edit().remove("draft_text").remove("draft_attachments").apply()
        draftRestoredBanner = false
    }

    // Auto-persist draft for new note capture so accidental dismissals never lose ideas
    LaunchedEffect(textValue.text, attachments.size, editNoteId) {
        if (editNoteId == null && !saving) {
            if (textValue.text.isBlank() && attachments.isEmpty()) {
                draftPrefs.edit().remove("draft_text").remove("draft_attachments").apply()
            } else {
                draftPrefs.edit()
                    .putString("draft_text", textValue.text)
                    .putString("draft_attachments", WhimCoreBridge.encodeAttachments(attachments.toList()))
                    .apply()
            }
        }
    }

    fun insertAtCursor(snippet: String) {
        val sel = textValue.selection
        val start = sel.min.coerceIn(0, textValue.text.length)
        val end = sel.max.coerceIn(start, textValue.text.length)
        val updated = textValue.text.substring(0, start) + snippet + textValue.text.substring(end)
        val newCursor = start + snippet.length
        textValue = TextFieldValue(text = updated, selection = TextRange(newCursor))
    }

    fun removeAttachmentToken(sha256: String) {
        val tokenRegex = Regex("\\n?!\\[[^\\]]*\\]\\(whim://blob/$sha256\\)\\n?")
        val cleaned = tokenRegex.replace(textValue.text, "\n").trim('\n')
        val pos = textValue.selection.end.coerceIn(0, cleaned.length)
        textValue = TextFieldValue(text = cleaned, selection = TextRange(pos))
    }

    fun ingestUri(uri: Uri) {
        scope.launch {
            runCatching {
                val mime = context.contentResolver.getType(uri) ?: "image/png"
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@runCatching
                val saved = WhimCoreBridge.saveBlob(bytes, mime)
                attachments.add(
                    WhimAttachment(
                        sha256 = saved.sha256,
                        mime = saved.mime,
                        sizeBytes = saved.sizeBytes,
                        localPath = saved.localPath
                    )
                )
                val curStart = textValue.selection.min.coerceIn(0, textValue.text.length)
                val needLeadingNL = curStart > 0 && textValue.text[curStart - 1] != '\n'
                val prefix = if (needLeadingNL) "\n" else ""
                insertAtCursor("${prefix}![image](whim://blob/${saved.sha256})\n")
            }
        }
    }

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri -> uri?.let { ingestUri(it) } }

    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
        initialImageUri?.let { ingestUri(it) }
        runCatching {
            allTags = flattenTags(WhimCoreBridge.listTagTree())
        }
    }

    val activeTagQuery = remember(textValue) {
        val cursor = textValue.selection.end.coerceIn(0, textValue.text.length)
        val beforeCursor = textValue.text.substring(0, cursor)
        val lastHash = beforeCursor.lastIndexOf('#')
        if (lastHash >= 0) {
            val tail = beforeCursor.substring(lastHash + 1)
            if (!tail.any { it.isWhitespace() }) tail else null
        } else null
    }
    val suggestions = remember(activeTagQuery, allTags) {
        if (activeTagQuery == null) emptyList()
        else allTags.filter { activeTagQuery.isEmpty() || it.contains(activeTagQuery, ignoreCase = true) }.take(6)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss
            )
            .imePadding()
            .padding(horizontal = 12.dp, vertical = 14.dp),
        contentAlignment = Alignment.BottomCenter
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(c.card)
                .border(1.2.dp, c.accent, RoundedCornerShape(14.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {}
                )
                .padding(16.dp)
        ) {
            // Header: 新建 / 编辑 + Draft indicator + Close
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(text = if (editNoteId != null) "编辑笔记" else "新建", style = t.section, color = c.textPrimary)
                    if (draftRestoredBanner && editNoteId == null) {
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(c.accent.copy(alpha = 0.14f))
                                .clickable {
                                    textValue = TextFieldValue("")
                                    attachments.clear()
                                    clearDraft()
                                }
                                .padding(horizontal = 7.dp, vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text("已恢复草稿 · 清空", style = t.meta, color = c.accent)
                        }
                    }
                }
                Icon(
                    Icons.Rounded.Close,
                    contentDescription = "关闭",
                    tint = c.textSecondary,
                    modifier = Modifier
                        .size(20.dp)
                        .clickable(onClick = onDismiss)
                )
            }

            Spacer(Modifier.height(12.dp))

            val tagVisual = remember(c.tagText, c.tagBg) {
                androidx.compose.ui.text.input.VisualTransformation { input ->
                    val styled = androidx.compose.ui.text.buildAnnotatedString {
                        append(input.text)
                        quickTagVisualRegex.findAll(input.text).forEach { m ->
                            val g = m.groups[2] ?: return@forEach
                            addStyle(
                                androidx.compose.ui.text.SpanStyle(
                                    color = c.tagText,
                                    background = c.tagBg
                                ),
                                start = g.range.first,
                                end = g.range.last + 1
                            )
                        }
                    }
                    androidx.compose.ui.text.input.TransformedText(
                        styled,
                        androidx.compose.ui.text.input.OffsetMapping.Identity
                    )
                }
            }

            BasicTextField(
                value = textValue,
                onValueChange = { textValue = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(148.dp)
                    .focusRequester(focusRequester),
                textStyle = t.body.copy(color = c.textPrimary),
                cursorBrush = SolidColor(c.accent),
                visualTransformation = tagVisual,
                decorationBox = { inner ->
                    if (text.isEmpty()) {
                        Text(text = "现在的想法是...", style = t.body, color = c.textMuted)
                    }
                    inner()
                }
            )

            if (suggestions.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    suggestions.forEach { tag ->
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(5.dp))
                                .background(c.tagBg)
                                .clickable {
                                    val cursor = textValue.selection.end.coerceIn(0, textValue.text.length)
                                    val before = textValue.text.substring(0, cursor)
                                    val idx = before.lastIndexOf('#')
                                    if (idx >= 0) {
                                        val replacement = "#$tag "
                                        val updated = textValue.text.substring(0, idx) + replacement + textValue.text.substring(cursor)
                                        textValue = TextFieldValue(text = updated, selection = TextRange(idx + replacement.length))
                                    }
                                }
                                .padding(horizontal = 8.dp, vertical = 4.dp)
                        ) {
                            Text(text = "#$tag", style = t.meta, color = c.tagText)
                        }
                    }
                }
            }

            if (attachments.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(attachments) { att ->
                        Box(
                            modifier = Modifier
                                .size(64.dp)
                                .clip(RoundedCornerShape(8.dp))
                        ) {
                            AsyncImage(
                                model = File(att.localPath),
                                contentDescription = "附件图片",
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize()
                            )
                            Box(
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .padding(3.dp)
                                    .size(18.dp)
                                    .clip(RoundedCornerShape(9.dp))
                                    .background(Color(0xAA000000))
                                    .clickable {
                                        attachments.remove(att)
                                        removeAttachmentToken(att.sha256)
                                    },
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(Icons.Rounded.Close, contentDescription = "移除", tint = Color.White, modifier = Modifier.size(11.dp))
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Bottom toolbar: # | image | paste | divider | bullet | number | task ... sage-green Send button
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    ToolbarIcon(Icons.Rounded.Tag, "标签") {
                        val cur = textValue.selection.min.coerceIn(0, textValue.text.length)
                        val needSpace = cur > 0 && !textValue.text[cur - 1].isWhitespace()
                        insertAtCursor(if (needSpace) " #" else "#")
                    }
                    ToolbarIcon(Icons.Rounded.Image, "选图") {
                        photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    }
                    ToolbarIcon(Icons.Rounded.ContentPaste, "贴图") {
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
                    Box(
                        modifier = Modifier
                            .width(1.dp)
                            .height(14.dp)
                            .background(c.border)
                    )
                    ToolbarIcon(Icons.AutoMirrored.Rounded.FormatListBulleted, "列表") {
                        val cur = textValue.selection.min.coerceIn(0, textValue.text.length)
                        val needNL = cur > 0 && textValue.text[cur - 1] != '\n'
                        insertAtCursor(if (needNL) "\n- " else "- ")
                    }
                    ToolbarIcon(Icons.Rounded.FormatListNumbered, "序号") {
                        val cur = textValue.selection.min.coerceIn(0, textValue.text.length)
                        val needNL = cur > 0 && textValue.text[cur - 1] != '\n'
                        insertAtCursor(if (needNL) "\n1. " else "1. ")
                    }
                    ToolbarIcon(Icons.Rounded.CheckBox, "待办") {
                        val cur = textValue.selection.min.coerceIn(0, textValue.text.length)
                        val needNL = cur > 0 && textValue.text[cur - 1] != '\n'
                        insertAtCursor(if (needNL) "\n- [ ] " else "- [ ] ")
                    }
                }

                // Flomo sage-green rounded send button
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(7.dp))
                        .background(if (canSubmit) c.accent else c.accent.copy(alpha = 0.45f))
                        .clickable(enabled = canSubmit) {
                            saving = true
                            scope.launch {
                                runCatching {
                                    if (editNoteId != null) {
                                        WhimCoreBridge.updateNote(
                                            id = editNoteId,
                                            content = text.trim(),
                                            attachments = attachments.toList()
                                        )
                                    } else {
                                        WhimCoreBridge.createNote(text.trim(), attachments.toList())
                                    }
                                }.onSuccess {
                                    if (editNoteId == null) clearDraft()
                                    onSaved()
                                }.onFailure {
                                    saving = false
                                }
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 7.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.AutoMirrored.Rounded.Send,
                        contentDescription = if (editNoteId != null) "保存" else "发送",
                        tint = Color.White.copy(alpha = if (canSubmit) 1f else 0.5f),
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolbarIcon(icon: ImageVector, desc: String, onClick: () -> Unit) {
    Icon(
        imageVector = icon,
        contentDescription = desc,
        tint = WhimTheme.colors.textSecondary,
        modifier = Modifier
            .size(20.dp)
            .clickable(onClick = onClick)
    )
}

private fun flattenTags(nodes: List<WhimTagNode>): List<String> {
    val out = mutableListOf<String>()
    fun walk(list: List<WhimTagNode>) {
        for (n in list) {
            out.add(n.fullPath)
            walk(n.children)
        }
    }
    walk(nodes)
    return out
}
