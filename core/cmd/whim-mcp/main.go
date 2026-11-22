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
					"version": "0.1.0",
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
			"description": "List Whim flash notes by optional date range (YYYY-MM-DD), multi-level tag prefix, or archive status.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"date_from":        map[string]string{"type": "string", "description": "Start date YYYY-MM-DD (inclusive)"},
					"date_to":          map[string]string{"type": "string", "description": "End date YYYY-MM-DD (inclusive)"},
					"tag_prefix":       map[string]string{"type": "string", "description": "Tag prefix such as 工作/架构"},
					"include_archived": map[string]string{"type": "boolean"},
					"limit":            map[string]string{"type": "integer"},
				},
			},
		},
		{
			"name":        "whim_search_notes",
			"description": "Search Whim notes by keyword across note content and tags.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"query": map[string]string{"type": "string", "description": "Search keyword"},
					"limit": map[string]string{"type": "integer"},
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
			"description": "Create a new Whim note (e.g., to save an AI daily review or synthesized insight).",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"content": map[string]string{"type": "string", "description": "Markdown content with optional #multi/level tags"},
				},
				"required": []string{"content"},
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
					"out_dir":    map[string]string{"type": "string", "description": "Destination folder path"},
					"date_from":  map[string]string{"type": "string"},
					"date_to":    map[string]string{"type": "string"},
					"tag_prefix": map[string]string{"type": "string"},
				},
				"required": []string{"out_dir"},
			},
		},
	}
}

func callTool(eng *engine.Engine, name string, rawArgs json.RawMessage) (string, bool) {
	switch name {
	case "whim_list_notes":
		var a struct {
			DateFrom        string `json:"date_from"`
			DateTo          string `json:"date_to"`
			TagPrefix       string `json:"tag_prefix"`
			IncludeArchived bool   `json:"include_archived"`
			Limit           int    `json:"limit"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		f := model.ListFilter{
			TagPrefix:       a.TagPrefix,
			IncludeArchived: a.IncludeArchived,
			Limit:           a.Limit,
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

	case "whim_search_notes":
		var a struct {
			Query string `json:"query"`
			Limit int    `json:"limit"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		notes, err := eng.Store.ListNotes(model.ListFilter{Query: a.Query, Limit: a.Limit, IncludeArchived: true})
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
		note, err := eng.Store.CreateNote(a.Content, nil)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(note, "", "  ")
		return string(b), false

	case "whim_update_tags":
		var a struct {
			NoteID     string   `json:"note_id"`
			AddTags    []string `json:"add_tags"`
			RemoveTags []string `json:"remove_tags"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		note, err := eng.Store.GetNote(a.NoteID)
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
		updated, err := eng.Store.UpdateNote(a.NoteID, &content, nil, nil, nil)
		if err != nil {
			return err.Error(), true
		}
		b, _ := json.MarshalIndent(updated, "", "  ")
		return string(b), false

	case "whim_export_markdown":
		var a struct {
			OutDir    string `json:"out_dir"`
			DateFrom  string `json:"date_from"`
			DateTo    string `json:"date_to"`
			TagPrefix string `json:"tag_prefix"`
		}
		_ = json.Unmarshal(rawArgs, &a)
		f := model.ListFilter{TagPrefix: a.TagPrefix}
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
