package export

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"whim/core/model"
	"whim/core/store"
)

// Result summarizes a Markdown export run.
type Result struct {
	OutputDir       string   `json:"output_dir"`
	FilesWritten    []string `json:"files_written"`
	NotesExported   int      `json:"notes_exported"`
	BlobsCopied     int      `json:"blobs_copied"`
}

// Markdown exports notes matching filter into daily YYYY-MM-DD.md files plus an attachments/ folder.
func Markdown(st *store.Store, f model.ListFilter, outDir string) (*Result, error) {
	if f.Limit <= 0 {
		f.Limit = 500
	}
	notes, err := st.ListNotes(f)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, err
	}
	attDir := filepath.Join(outDir, "attachments")

	byDay := make(map[string][]model.Note)
	for _, n := range notes {
		day := time.UnixMilli(n.CreatedAt).Format("2006-01-02")
		byDay[day] = append(byDay[day], n)
	}

	days := make([]string, 0, len(byDay))
	for d := range byDay {
		days = append(days, d)
	}
	sort.Strings(days)

	res := &Result{
		OutputDir:     outDir,
		NotesExported: len(notes),
	}
	copiedBlobs := make(map[string]struct{})

	for _, day := range days {
		dayNotes := byDay[day]
		sort.Slice(dayNotes, func(i, j int) bool {
			return dayNotes[i].CreatedAt < dayNotes[j].CreatedAt
		})

		var sb strings.Builder
		sb.WriteString(fmt.Sprintf("# %s\n\n", day))
		for _, n := range dayNotes {
			ts := time.UnixMilli(n.CreatedAt).Format("15:04")
			sb.WriteString(fmt.Sprintf("### %s\n\n", ts))

			body := strings.TrimSpace(n.Content)
			var trailing []string
			for _, att := range n.Attachments {
				src, ok := st.BlobPath(att.SHA256)
				if !ok {
					continue
				}
				if err := os.MkdirAll(attDir, 0o755); err != nil {
					return nil, err
				}
				base := filepath.Base(src)
				dst := filepath.Join(attDir, base)
				if _, done := copiedBlobs[base]; !done {
					if err := copyFile(src, dst); err != nil {
						return nil, err
					}
					copiedBlobs[base] = struct{}{}
					res.BlobsCopied++
				}
				inlineToken := fmt.Sprintf("whim://blob/%s", att.SHA256)
				if strings.Contains(body, inlineToken) {
					body = strings.ReplaceAll(body, inlineToken, "attachments/"+base)
				} else {
					trailing = append(trailing, fmt.Sprintf("![](attachments/%s)", base))
				}
			}
			sb.WriteString(body)
			sb.WriteString("\n")
			for _, imgMd := range trailing {
				sb.WriteString("\n" + imgMd + "\n")
			}
			sb.WriteString("\n")
		}

		outFile := filepath.Join(outDir, day+".md")
		if err := os.WriteFile(outFile, []byte(sb.String()), 0o644); err != nil {
			return nil, err
		}
		res.FilesWritten = append(res.FilesWritten, outFile)
	}

	return res, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}
