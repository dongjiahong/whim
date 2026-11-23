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
 * Flomo-style instant floating capture sheet launched from Quick Settings Tile,
 * Home Screen Widget, Share Sheet, or main FAB.
 */
class QuickCaptureActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WhimCoreBridge.ensureInit(this)

        val sharedText = if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
        } else ""

        val sharedImageUri: Uri? = if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("image/") == true) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
        } else null

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
                    initialText = sharedText,
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

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FlomoQuickCaptureSheet(
    initialText: String = "",
    initialImageUri: Uri? = null,
    onDismiss: () -> Unit,
    onSaved: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }

    var text by remember { mutableStateOf(initialText) }
    val attachments = remember { mutableStateListOf<WhimAttachment>() }
    var allTags by remember { mutableStateOf<List<String>>(emptyList()) }
    var saving by remember { mutableStateOf(false) }

    val canSubmit = !saving && (text.isNotBlank() || attachments.isNotEmpty())

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
                // Insert inline image token directly into the document text at current end
                val prefix = if (text.isNotEmpty() && !text.endsWith("\n")) "\n" else ""
                text += "${prefix}![image](whim://blob/${saved.sha256})\n"
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

    val activeTagQuery = remember(text) {
        val lastHash = text.lastIndexOf('#')
        if (lastHash >= 0) {
            val tail = text.substring(lastHash + 1)
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
                .clip(RoundedCornerShape(12.dp))
                .background(c.card)
                .border(1.2.dp, c.accent, RoundedCornerShape(12.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {}
                )
                .padding(16.dp)
        ) {
            // Header: 新建 + Close
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(text = "新建", style = t.section, color = c.textPrimary)
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

            BasicTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(136.dp)
                    .focusRequester(focusRequester),
                textStyle = t.body.copy(color = c.textPrimary),
                cursorBrush = SolidColor(c.accent),
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
                                    val idx = text.lastIndexOf('#')
                                    if (idx >= 0) {
                                        text = text.substring(0, idx) + "#$tag "
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
                                    .clickable { attachments.remove(att) },
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(Icons.Rounded.Close, contentDescription = "移除", tint = Color.White, modifier = Modifier.size(11.dp))
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Bottom toolbar: # | image | paste | divider | bullet | number ... sage-green Send button
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
                        text += if (text.isEmpty() || text.endsWith(" ") || text.endsWith("\n")) "#" else " #"
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
                                !item.text.isNullOrBlank() -> text += item.text.toString()
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
                        text += if (text.isEmpty() || text.endsWith("\n")) "- " else "\n- "
                    }
                    ToolbarIcon(Icons.Rounded.FormatListNumbered, "序号") {
                        text += if (text.isEmpty() || text.endsWith("\n")) "1. " else "\n1. "
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
                                    WhimCoreBridge.createNote(text.trim(), attachments.toList())
                                }.onSuccess {
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
                        contentDescription = "发送",
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
