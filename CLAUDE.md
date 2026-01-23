# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal website (jxxcarlson.org) built with Hakyll, a Haskell static site generator. The site uses a custom markup language called Scripta for content processing and deploys to Cloudflare Pages.

## Build & Development Commands

```bash
# Development (kills port 8000, builds, and watches for changes)
sh scripts/refresh.sh

# Build only
stack build && stack exec site rebuild

# Deploy to Cloudflare
sh scripts/deploy.sh

# Watch archive and auto-deploy on changes (run in background)
sh scripts/watch_and_deploy.sh &

# Convert PNG/JPG to WebP
sh scripts/convert-images.sh
```

Development server runs on port 8000. Generated site outputs to `_site/`.

## Architecture

### Core Modules

- **Site.hs** - Main Hakyll configuration: route definitions, context builders, archive scanning, tag indexing, link map building
- **Scripta.hs** - Custom markup processor that transforms content before Pandoc processing

### Scripta Markup Language

Block elements (standalone lines):
- `[image filename]`, `[slideshow images]`, `[pdf filename]`
- `[audio filename title]`, `[video filename]`
- `[prog Title Filename]` - embed from /prog directory
- `[equation] ... [/equation]` - LaTeX math block
- `[theorem Title] ... [/theorem]`, `[quotation] ... [/quotation]`
- `[indent] ... [/indent]`, `[center] ... [/center]`
- `[vspace N]`, `[hide]`

Inline elements (within text):
- `[i text]`, `[b text]`, `[u text]` - italic, bold, underline
- `[ilink ZETTELID]` or `[ilink ZETTELID "custom text"]` - internal links
- `[link Label URL]` - external links
- `[prog Title File]` - inline program link
- `[hrule]`, `[par]`

### Content Types

| Type | Location | Format | Notes |
|------|----------|--------|-------|
| Blog Posts | `/posts/YYYY-MM-DD-*.md` | Markdown | Date in filename |
| Archive Notes | `/archive/YYYYMMDDHHMMSS-*.txt` | Plain text | Zettelkasten IDs, tags (#diary, #memoirs, #note, #post) |
| Photography | `/photography/*.md` | Markdown | Gallery with index |
| Music | `/music/*.md` | Markdown | Composition entries |
| Art | `/art/*.md` | Markdown | Portfolio entries |
| Programs | `/prog/**` | HTML/JS/Elm | Embedded interactive apps |

### Zettelkasten System

Archive files use 14-digit timestamps (YYYYMMDDHHMMSS) as IDs. These enable:
- Automatic date extraction for sorting
- Internal linking via `[ilink ID]`
- Link map resolution at build time

Tags in archive files (`#diary`, `#memoirs`, `#note`, `#post`, `#tag:xyz`) generate filtered index pages.

### Templates

Located in `/templates/`. Key templates: `default.html` (base layout with nav and KaTeX), `post.html`, `blog.html`, `note.html`, `notes.html`, `photography.html`, `art.html`.

## Key Technical Details

- **Stack resolver**: lts-22.43
- **Dependencies**: hakyll >=4.15, pandoc, text, containers
- **Math rendering**: KaTeX 0.16.9 (loaded via CDN)
- **Deployment**: Cloudflare Pages via wrangler CLI
- **Image format**: WebP (converted from PNG/JPG)

## Archive Path

The archive directory is symlinked from `~/Dropbox/theARCHIVE`. The `watch_and_deploy.sh` script monitors this location and auto-deploys after 5 minutes of inactivity.
