package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"whim/core/engine"
	"whim/core/model"
	"whim/core/tags"
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      any       `json:"id,omitempty"`
	Result  any       `json:"result,omitempty"`
	Error   *rpcError `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func defaultDataDir() string {
	if env := os.Getenv("WHIM_DATA_DIR"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Whim")
}

func main() {
	dataDir := flag.String("data-dir", defaultDataDir(), "Whim data directory containing whim.sqlite3")
	flag.Parse()

	eng, err := engine.Open(*dataDir, "whim-mcp")
	if err != nil {
		fmt.Fprintf(os.Stderr, "whim-mcp: open store failed: %v\n", err)
		os.Exit(1)
	}
	defer eng.Close()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	enc := json.NewEncoder(os.Stdout)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			_ = enc.Encode(rpcResponse{
				JSONRPC: "2.0",
				Error:   &rpcError{Code: -32700, Message: "parse error"},
			})
			continue
		}
		// Notifications have no ID and expect no response.
		if req.ID == nil && strings.HasPrefix(req.Method, "notifications/") {
			continue
		}
		resp := handleRPC(eng, req)
		_ = enc.Encode(resp)
	}
}

func handleRPC(eng *engine.Engine, req rpcRequest) rpcResponse {
	switch req.Method {
	case "initialize":
		return rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities": map[string]any{
					"tools": map[string]any{},
				},
				"serverInfo": map[string]string{
					"name":    "whim-mcp",
					"version": "0.2.0",
				},
			},
		}
	case "ping":
		return rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
	case "tools/list":
		return rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  map[string]any{"tools": toolDefinitions()},
		}
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -32602, Message: "invalid params"}}
		}
		text, isErr := callTool(eng, p.Name, p.Arguments)
		return rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"content": []map[string]string{{"type": "text", "text": text}},
				"isError": isErr,
			},
		}
	default:
		return rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &rpcError{Code: -32601, Message: "method not found: " + req.Method},
		}
	}
}

func toolDefinitions() []map[string]any {
	return []map[string]any{
		{
			"name":        "whim_list_notes",
			"description": "List Whim flash notes by optional date range (YYYY-MM-DD), multi-level tag prefix, excluded tag prefixes (e.g. 'AI' to omit prior AI summaries), or archive status.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"date_from":            map[string]string{"type": "string", "description": "Start date YYYY-MM-DD (inclusive)"},
					"date_to":              map[string]string{"type": "string", "description": "End date YYYY-MM-DD (inclusive)"},
					"tag_prefix":           map[string]string{"type": "string", "description": "Include only notes under this tag prefix, e.g. 心得 or 工作/架构"},
					"exclude_tag_prefix":   map[string]string{"type": "string", "description": "Exclude notes under this tag prefix, e.g. AI or AI/心得"},
					"exclude_tag_prefixes": map[string]any{"type": "array", "items": map[string]string{"type": "string"}, "description": "Exclude notes matching any of these tag prefixes"},
					"include_archived":     map[string]string{"type": "boolean"},
					"include_replies":      map[string]string{"type": "boolean", "description": "Whether to include thread replies (追记) in the flat list (default false)"},
					"limit":                map[string]string{"type": "integer"},
				},
			},
		},
		{
			"name":        "whim_get_note",
			"description": "Fetch a single Whim note by ID, optionally including its chronological thread replies (追记).",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"note_id":         map[string]string{"type": "string", "description": "Target note ID"},
					"include_replies": map[string]string{"type": "boolean", "description": "Whether to include thread replies (default true)"},
				},
				"required": []string{"note_id"},
			},
		},
		{
			"name":        "whim_search_notes",
			"description": "Search Whim notes by keyword across note content and tags, with optional tag prefix exclusions.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"query":                map[string]string{"type": "string", "description": "Search keyword"},
					"exclude_tag_prefix":   map[string]string{"type": "string", "description": "Exclude notes under this tag prefix, e.g. AI"},
					"exclude_tag_prefixes": map[string]any{"type": "array", "items": map[string]string{"type": "string"}},
					"limit":                map[string]string{"type": "integer"},
				},
				"required": []string{"query"},
			},
		},
		{
			"name":        "whim_list_tags",
			"description": "Return the hierarchical multi-level tag tree with note counts.",
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
		},
		{
			"name":        "whim_create_note",
			"description": "Create a new Whim note (e.g., to save an AI weekly review or synthesized insight with #AI/心得/每周总结).",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"content": map[string]string{"type": "string", "description": "Markdown content with optional #multi/level tags"},
				},
				"required": []string{"content"},
			},
		},
		{
			"name":        "whim_update_note",
			"description": "Update an existing Whim note's Markdown content, pinned status, or archived status by ID.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"note_id":  map[string]string{"type": "string", "description": "Target note ID"},
					"content":  map[string]string{"type": "string", "description": "Replacement Markdown content (inline #tags are re-indexed automatically)"},
					"pinned":   map[string]string{"type": "boolean", "description": "Optional pinned flag"},
					"archived": map[string]string{"type": "boolean", "description": "Optional archived flag"},
				},
				"required": []string{"note_id"},
			},
		},
		{
			"name":        "whim_list_replies",
			"description": "List all thread replies (追记) attached to a parent note in chronological order.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"note_id": map[string]string{"type": "string", "description": "Parent note ID"},
				},
				"required": []string{"note_id"},
			},
		},
		{
			"name":        "whim_add_reply",
			"description": "Append a new thread reply (追记) to an existing Whim note.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"note_id": map[string]string{"type": "string", "description": "Parent note ID"},
					"content": map[string]string{"type": "string", "description": "Markdown content of the reply"},
				},
				"required": []string{"note_id", "content"},
			},
		},
		{
			"name":        "whim_update_tags",
			"description": "Add or remove multi-level tags on an existing note by ID.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"note_id":     map[string]string{"type": "string"},
					"add_tags":    map[string]any{"type": "array", "items": map[string]string{"type": "string"}},
					"remove_tags": map[string]any{"type": "array", "items": map[string]string{"type": "string"}},
				},
				"required": []string{"note_id"},
			},
		},
		{
			"name":        "whim_export_markdown",
			"description": "Export matching Whim notes and attached images to daily Markdown files.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"out_dir":              map[string]string{"type": "string", "description": "Destination folder path"},
					"date_from":            map[string]string{"type": "string"},
					"date_to":              map[string]string{"type": "string"},
					"tag_prefix":           map[string]string{"type": "string"},
					"exclude_tag_prefix":   map[string]string{"type": "string"},
					"exclude_tag_prefixes": map[string]any{"type": "array", "items": map[string]string{"type": "string"}},
				},
				"required": []string{"out_dir"},
			},
		},
	}
}

func mergeExcludePrefixes(single string, many []string) []string {
	var out []string
	seen := make(map[string]bool)
	add := func(raw string) {
		norm := tags.Normalize(raw)
		if norm != "" && !seen[norm] {
			seen[norm] = true
			out = append(out, norm)
		}
	}
	add(single)
	for _, s := range many {
		add(s)
	}
	return out
}

func callTool(eng *engine.Engine, name string, rawArgs json.RawMessage) (string, bool) {
	switch name {
	case "whim_list_notes":
		var a struct {
			DateFrom           string   `json:"date_from"`
			DateTo             string   `json:"date_to"`
			TagPrefix          string   `json:"tag_prefix"`
			ExcludeTagPrefix   string   `json:"exclude_tag_prefix"`
			ExcludeTagPrefixes []string `json:"exclude_tag_prefixes"`
			IncludeArchived    bool     `json:"include_archived"`
			IncludeReplies     bool     `json:"include_replies"`
			Limit              int      `json:"limit"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		f := model.ListFilter{
			TagPrefix:          a.TagPrefix,
			ExcludeTagPrefixes: mergeExcludePrefixes(a.ExcludeTagPrefix, a.ExcludeTagPrefixes),
			IncludeArchived:    a.IncludeArchived,
			IncludeReplies:     a.IncludeReplies,
			Limit:              a.Limit,
		}
		if a.DateFrom != "" {
			if t, err := time.ParseInLocation("2006-01-02", a.DateFrom, time.Local); err == nil {
				f.DateFromMs = t.UnixMilli()
			}
		}
		if a.DateTo != "" {
			if t, err := time.ParseInLocation("2006-01-02", a.DateTo, time.Local); err == nil {
				f.DateToMs = t.Add(24*time.Hour - time.Millisecond).UnixMilli()
			}
		}
		notes, err := eng.Store.ListNotes(f)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(notes, "", "  ")
		return string(b), false

	case "whim_get_note":
		var a struct {
			NoteID         string `json:"note_id"`
			IncludeReplies *bool  `json:"include_replies"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		noteID := strings.TrimSpace(a.NoteID)
		if noteID == "" {
			return "note_id is required", true
		}
		note, err := eng.Store.GetNote(noteID)
		if err != nil {
			return err.Error(), true
		}
		includeReplies := true
		if a.IncludeReplies != nil {
			includeReplies = *a.IncludeReplies
		}
		if !includeReplies {
			b, _ := json.MarshalIndent(note, "", "  ")
			return string(b), false
		}
		replies, err := eng.Store.ListReplies(noteID)
		if err != nil {
			return err.Error(), true
		}
		res := map[string]any{
			"note":    note,
			"replies": replies,
		}
		b, _ := json.MarshalIndent(res, "", "  ")
		return string(b), false

	case "whim_search_notes":
		var a struct {
			Query              string   `json:"query"`
			ExcludeTagPrefix   string   `json:"exclude_tag_prefix"`
			ExcludeTagPrefixes []string `json:"exclude_tag_prefixes"`
			Limit              int      `json:"limit"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		notes, err := eng.Store.ListNotes(model.ListFilter{
			Query:              a.Query,
			ExcludeTagPrefixes: mergeExcludePrefixes(a.ExcludeTagPrefix, a.ExcludeTagPrefixes),
			Limit:              a.Limit,
			IncludeArchived:    true,
		})
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(notes, "", "  ")
		return string(b), false

	case "whim_list_tags":
		tree, err := eng.Store.ListTagTree()
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(tree, "", "  ")
		return string(b), false

	case "whim_create_note":
		var a struct {
			Content string `json:"content"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		if strings.TrimSpace(a.Content) == "" {
			return "content is required", true
		}
		note, err := eng.Store.CreateNote(a.Content, nil)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(note, "", "  ")
		return string(b), false

	case "whim_update_note":
		var a struct {
			NoteID   string  `json:"note_id"`
			Content  *string `json:"content"`
			Pinned   *bool   `json:"pinned"`
			Archived *bool   `json:"archived"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		noteID := strings.TrimSpace(a.NoteID)
		if noteID == "" {
			return "note_id is required", true
		}
		if a.Content == nil && a.Pinned == nil && a.Archived == nil {
			return "at least one of content, pinned, or archived must be provided", true
		}
		updated, err := eng.Store.UpdateNote(noteID, a.Content, a.Pinned, a.Archived, nil)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(updated, "", "  ")
		return string(b), false

	case "whim_list_replies":
		var a struct {
			NoteID string `json:"note_id"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		noteID := strings.TrimSpace(a.NoteID)
		if noteID == "" {
			return "note_id is required", true
		}
		replies, err := eng.Store.ListReplies(noteID)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(replies, "", "  ")
		return string(b), false

	case "whim_add_reply":
		var a struct {
			NoteID  string `json:"note_id"`
			Content string `json:"content"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		noteID := strings.TrimSpace(a.NoteID)
		if noteID == "" {
			return "note_id is required", true
		}
		if strings.TrimSpace(a.Content) == "" {
			return "content is required", true
		}
		if _, err := eng.Store.GetNote(noteID); err != nil {
			return fmt.Sprintf("parent note not found: %v", err), true
		}
		reply, err := eng.Store.CreateReply(noteID, a.Content, nil)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(reply, "", "  ")
		return string(b), false

	case "whim_update_tags":
		var a struct {
			NoteID     string   `json:"note_id"`
			AddTags    []string `json:"add_tags"`
			RemoveTags []string `json:"remove_tags"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		noteID := strings.TrimSpace(a.NoteID)
		if noteID == "" {
			return "note_id is required", true
		}
		note, err := eng.Store.GetNote(noteID)
		if err != nil {
			return err.Error(), true
		}
		content := note.Content
		for _, rt := range a.RemoveTags {
			norm := tags.Normalize(rt)
			if norm != "" {
				content = strings.ReplaceAll(content, "#"+norm, "")
			}
		}
		existing := make(map[string]bool)
		for _, et := range tags.Extract(content) {
			existing[et] = true
		}
		var toAppend []string
		for _, at := range a.AddTags {
			norm := tags.Normalize(at)
			if norm != "" && !existing[norm] {
				toAppend = append(toAppend, "#"+norm)
			}
		}
		if len(toAppend) > 0 {
			content = strings.TrimSpace(content) + "\n" + strings.Join(toAppend, " ")
		}
		updated, err := eng.Store.UpdateNote(noteID, &content, nil, nil, nil)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(updated, "", "  ")
		return string(b), false

	case "whim_export_markdown":
		var a struct {
			OutDir             string   `json:"out_dir"`
			DateFrom           string   `json:"date_from"`
			DateTo             string   `json:"date_to"`
			TagPrefix          string   `json:"tag_prefix"`
			ExcludeTagPrefix   string   `json:"exclude_tag_prefix"`
			ExcludeTagPrefixes []string `json:"exclude_tag_prefixes"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		f := model.ListFilter{
			TagPrefix:          a.TagPrefix,
			ExcludeTagPrefixes: mergeExcludePrefixes(a.ExcludeTagPrefix, a.ExcludeTagPrefixes),
		}
		if a.DateFrom != "" {
			if t, err := time.ParseInLocation("2006-01-02", a.DateFrom, time.Local); err == nil {
				f.DateFromMs = t.UnixMilli()
			}
		}
		if a.DateTo != "" {
			if t, err := time.ParseInLocation("2006-01-02", a.DateTo, time.Local); err == nil {
				f.DateToMs = t.Add(24*time.Hour - time.Millisecond).UnixMilli()
			}
		}
		res, err := eng.ExportMarkdown(f, a.OutDir)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(res, "", "  ")
		return string(b), false

	default:
		return "unknown tool: " + name, true
	}
}
