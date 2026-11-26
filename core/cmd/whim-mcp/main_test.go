package main

import (
	"encoding/json"
	"strings"
	"testing"

	"whim/core/engine"
	"whim/core/model"
)

func openTestEngine(t *testing.T) *engine.Engine {
	t.Helper()
	eng, err := engine.Open(t.TempDir(), "whim-mcp-test")
	if err != nil {
		t.Fatalf("open engine: %v", err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	return eng
}

func mustCall(t *testing.T, eng *engine.Engine, tool string, args any) string {
	t.Helper()
	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	out, isErr := callTool(eng, tool, raw)
	if isErr {
		t.Fatalf("tool %s returned error: %s", tool, out)
	}
	return out
}

func TestExcludeTagPrefixFiltering(t *testing.T) {
	eng := openTestEngine(t)

	_, err := eng.Store.CreateNote("今天对价格行为有新体会 #心得/交易", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = eng.Store.CreateNote("本周心得总结初稿 #AI/心得/每周总结", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = eng.Store.CreateNote("草稿备忘 #临时/草稿", nil)
	if err != nil {
		t.Fatal(err)
	}

	// Exclude #AI prefix
	out := mustCall(t, eng, "whim_list_notes", map[string]any{
		"exclude_tag_prefix": "AI",
	})
	var notes []model.Note
	if err := json.Unmarshal([]byte(out), &notes); err != nil {
		t.Fatalf("unmarshal notes: %v", err)
	}
	if len(notes) != 2 {
		t.Fatalf("expected 2 notes after excluding AI, got %d", len(notes))
	}
	for _, n := range notes {
		if strings.Contains(n.Content, "#AI/") {
			t.Fatalf("unexpected AI note returned: %s", n.Content)
		}
	}

	// Exclude multiple prefixes
	out = mustCall(t, eng, "whim_list_notes", map[string]any{
		"exclude_tag_prefixes": []string{"#AI", "临时"},
	})
	notes = nil
	if err := json.Unmarshal([]byte(out), &notes); err != nil {
		t.Fatalf("unmarshal notes: %v", err)
	}
	if len(notes) != 1 || !strings.Contains(notes[0].Content, "#心得/交易") {
		t.Fatalf("expected only #心得/交易 note, got %+v", notes)
	}
}

func TestUpdateNoteAndRepliesFlow(t *testing.T) {
	eng := openTestEngine(t)

	// 1. Create a summary note
	createdJSON := mustCall(t, eng, "whim_create_note", map[string]any{
		"content": "## 2026-W48 心得周报\n初稿内容 #AI/心得/每周总结",
	})
	var created model.Note
	if err := json.Unmarshal([]byte(createdJSON), &created); err != nil {
		t.Fatalf("unmarshal created: %v", err)
	}

	// 2. Update the summary note content & pin it
	updatedJSON := mustCall(t, eng, "whim_update_note", map[string]any{
		"note_id": created.ID,
		"content": "## 2026-W48 心得周报\n修订后的定稿内容 #AI/心得/每周总结 #复盘",
		"pinned":  true,
	})
	var updated model.Note
	if err := json.Unmarshal([]byte(updatedJSON), &updated); err != nil {
		t.Fatalf("unmarshal updated: %v", err)
	}
	if !updated.Pinned || !strings.Contains(updated.Content, "修订后的定稿内容") {
		t.Fatalf("unexpected updated note: %+v", updated)
	}

	// 3. Append a reply (追记)
	replyJSON := mustCall(t, eng, "whim_add_reply", map[string]any{
		"note_id": created.ID,
		"content": "追记：下周重点验证入场耐心",
	})
	var reply model.Note
	if err := json.Unmarshal([]byte(replyJSON), &reply); err != nil {
		t.Fatalf("unmarshal reply: %v", err)
	}
	if reply.ParentID != created.ID {
		t.Fatalf("expected reply parent_id=%s, got %s", created.ID, reply.ParentID)
	}

	// 4. List replies
	repliesJSON := mustCall(t, eng, "whim_list_replies", map[string]any{
		"note_id": created.ID,
	})
	var replies []model.Note
	if err := json.Unmarshal([]byte(repliesJSON), &replies); err != nil {
		t.Fatalf("unmarshal replies: %v", err)
	}
	if len(replies) != 1 || replies[0].ID != reply.ID {
		t.Fatalf("expected 1 reply matching %s, got %+v", reply.ID, replies)
	}

	// 5. Get note with replies included by default
	detailJSON := mustCall(t, eng, "whim_get_note", map[string]any{
		"note_id": created.ID,
	})
	var detail struct {
		Note    model.Note   `json:"note"`
		Replies []model.Note `json:"replies"`
	}
	if err := json.Unmarshal([]byte(detailJSON), &detail); err != nil {
		t.Fatalf("unmarshal detail: %v", err)
	}
	if detail.Note.ID != created.ID || len(detail.Replies) != 1 {
		t.Fatalf("unexpected get_note response: %+v", detail)
	}
}

func TestToolsListCount(t *testing.T) {
	eng := openTestEngine(t)
	resp := handleRPC(eng, rpcRequest{JSONRPC: "2.0", ID: 1, Method: "tools/list"})
	if resp.Error != nil {
		t.Fatalf("tools/list error: %+v", resp.Error)
	}
	resMap, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatalf("unexpected result type: %T", resp.Result)
	}
	tools, ok := resMap["tools"].([]map[string]any)
	if !ok {
		t.Fatalf("unexpected tools type: %T", resMap["tools"])
	}
	if len(tools) != 10 {
		t.Fatalf("expected 10 MCP tools, got %d", len(tools))
	}
}
