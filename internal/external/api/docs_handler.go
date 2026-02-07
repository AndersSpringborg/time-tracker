package api

import (
	"bytes"
	"fmt"
	"html/template"
	"net/http"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
)

var docsMarkdown = goldmark.New(
	goldmark.WithExtensions(extension.GFM),
	goldmark.WithParserOptions(parser.WithAutoHeadingID()),
)

func (s *Server) handleDocs(w http.ResponseWriter, r *http.Request) {
	md, err := assets.ReadFile("content/getting-started.md")
	if err != nil {
		s.internalError(w, r, fmt.Errorf("read docs markdown: %w", err))
		return
	}

	var out bytes.Buffer
	if err := docsMarkdown.Convert(md, &out); err != nil {
		s.internalError(w, r, fmt.Errorf("render docs markdown: %w", err))
		return
	}

	body := template.HTML(`<section class="card docs">` + out.String() + `</section>`)
	s.render(w, "layout", pageData{
		Title:    "Docs",
		Page:     "docs",
		BodyHTML: body,
	})
}
