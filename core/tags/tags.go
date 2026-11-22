package tags

import (
	"sort"
	"strings"
	"unicode"

	"whim/core/model"
)

// Extract parses multi-level #tag/subtag/leaf tokens from note content.
// Rules:
// - '#' must be at start of string or preceded by whitespace or CJK punctuation.
// - Allowed characters in tag segments: letters (including CJK), digits, '_', '-', '/'.
// - Leading/trailing '/' and empty segments are trimmed; deduplicated and sorted.
func Extract(content string) []string {
	runes := []rune(content)
	seen := make(map[string]struct{})
	var result []string

	for i := 0; i < len(runes); i++ {
		if runes[i] != '#' {
			continue
		}
		if i > 0 && !isTagBoundary(runes[i-1]) {
			continue
		}
		// Skip markdown headings like "# Heading" (space after #) or "##"
		if i+1 >= len(runes) || runes[i+1] == '#' || unicode.IsSpace(runes[i+1]) {
			continue
		}
		j := i + 1
		for j < len(runes) && isTagChar(runes[j]) {
			j++
		}
		raw := string(runes[i+1 : j])
		clean := Normalize(raw)
		if clean != "" {
			if _, ok := seen[clean]; !ok {
				seen[clean] = struct{}{}
				result = append(result, clean)
			}
		}
		i = j - 1
	}
	sort.Strings(result)
	return result
}

// Normalize cleans a tag path by stripping '#' prefix, empty segments, and extra slashes.
func Normalize(raw string) string {
	raw = strings.TrimPrefix(strings.TrimSpace(raw), "#")
	if raw == "" {
		return ""
	}
	parts := strings.Split(raw, "/")
	cleanParts := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			cleanParts = append(cleanParts, p)
		}
	}
	return strings.Join(cleanParts, "/")
}

func isTagBoundary(r rune) bool {
	return unicode.IsSpace(r) || strings.ContainsRune("([{（【「『，。、；：！？,.;:!?", r)
}

func isTagChar(r rune) bool {
	if unicode.IsLetter(r) || unicode.IsDigit(r) {
		return true
	}
	return r == '/' || r == '_' || r == '-'
}

// BuildTree builds a hierarchical tag tree from a map of full tag path -> note count.
// Parent nodes accumulate counts from direct notes + descendants.
func BuildTree(counts map[string]int) []model.TagNode {
	type nodeBuilder struct {
		name     string
		fullPath string
		direct   int
		children map[string]*nodeBuilder
	}
	root := &nodeBuilder{children: make(map[string]*nodeBuilder)}

	for path, cnt := range counts {
		clean := Normalize(path)
		if clean == "" || cnt <= 0 {
			continue
		}
		segs := strings.Split(clean, "/")
		curr := root
		var prefix string
		for idx, seg := range segs {
			if idx == 0 {
				prefix = seg
			} else {
				prefix = prefix + "/" + seg
			}
			child, ok := curr.children[seg]
			if !ok {
				child = &nodeBuilder{
					name:     seg,
					fullPath: prefix,
					children: make(map[string]*nodeBuilder),
				}
				curr.children[seg] = child
			}
			curr = child
		}
		curr.direct += cnt
	}

	var finalize func(b *nodeBuilder) (model.TagNode, int)
	finalize = func(b *nodeBuilder) (model.TagNode, int) {
		keys := make([]string, 0, len(b.children))
		for k := range b.children {
			keys = append(keys, k)
		}
		sort.Strings(keys)

		total := b.direct
		children := make([]model.TagNode, 0, len(keys))
		for _, k := range keys {
			cn, sub := finalize(b.children[k])
			total += sub
			children = append(children, cn)
		}
		return model.TagNode{
			Name:     b.name,
			FullPath: b.fullPath,
			Count:    total,
			Children: children,
		}, total
	}

	keys := make([]string, 0, len(root.children))
	for k := range root.children {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]model.TagNode, 0, len(keys))
	for _, k := range keys {
		n, _ := finalize(root.children[k])
		out = append(out, n)
	}
	return out
}
