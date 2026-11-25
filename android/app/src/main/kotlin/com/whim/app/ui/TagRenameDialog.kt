package com.whim.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.whim.app.ui.theme.WhimTheme

/**
 * Dialog for renaming or merging a tag prefix (#oldTag -> #newTag) across all notes.
 */
@Composable
fun TagRenameDialog(
    oldTag: String,
    isRenaming: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    var input by remember(oldTag) { mutableStateOf(oldTag) }
    val cleaned = input.trim().trimStart('#').trim('/')
    val canSubmit = !isRenaming && cleaned.isNotEmpty() && cleaned != oldTag

    Dialog(
        onDismissRequest = { if (!isRenaming) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(c.card)
                .border(0.8.dp, c.border, RoundedCornerShape(18.dp))
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("整理 / 合并标签", style = t.title, color = c.textPrimary)
                Text(
                    "将 #$oldTag 及其子标签批量改为新名称；若目标标签已存在，会自动合并。",
                    style = t.meta,
                    color = c.textSecondary
                )
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(c.canvas)
                    .border(0.8.dp, c.border, RoundedCornerShape(10.dp))
                    .padding(horizontal = 12.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text("#", style = t.body, fontWeight = FontWeight.SemiBold, color = c.accent)
                BasicTextField(
                    value = input,
                    onValueChange = { input = it },
                    singleLine = true,
                    textStyle = t.body.copy(color = c.textPrimary),
                    cursorBrush = SolidColor(c.accent),
                    modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        if (input.isEmpty()) Text("输入新标签名（如 读书/笔记）", style = t.body, color = c.textMuted)
                        inner()
                    }
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.canvas)
                        .clickable(enabled = !isRenaming, onClick = onDismiss)
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("取消", style = t.body, color = c.textSecondary)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (canSubmit) c.accent else c.canvas)
                        .clickable(enabled = canSubmit) { onConfirm(cleaned) }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        if (isRenaming) "处理中..." else "确认修改",
                        style = t.body,
                        fontWeight = FontWeight.SemiBold,
                        color = if (canSubmit) Color.White else c.textMuted
                    )
                }
            }
        }
    }
}
