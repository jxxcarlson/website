# Grab Feature

A tool that fetches a web page by URL, strips advertising/scripts/noise, and converts the content to clean Markdown or Scripta markup for download.

## Architecture

Two executables defined in `package.yaml`:

- `site` — existing Hakyll static site generator
- `grab-server` — Scotty web server on port 8080

Both share `src/` modules. The grab server runs independently from the static site.

## Files

| File | Purpose |
|------|---------|
| `src/Grab.hs` | URL fetching, HTML cleaning, Markdown/Scripta conversion |
| `src/GrabServer.hs` | Scotty server with `POST /api/grab` endpoint |
| `content/pages/grab.md` | Grab page UI (URL input + format selector) |
| `js/grab.js` | Client-side fetch and file download logic |

## How to Use

1. Build everything: `stack build`
2. Start the grab server: `stack exec grab-server`
3. Start the site: `stack exec site watch`
4. Open `http://localhost:8000/grab.html`
5. Enter a URL, select Markdown or Scripta, click Grab
6. The converted document downloads automatically

## API

**Endpoint:** `POST http://localhost:8080/api/grab`

**Request:**
```json
{ "url": "https://example.com/article", "format": "md" }
```

Format is `"md"` for Markdown or `"scripta"` for Scripta.

**Response:** Plain text document with `X-Filename` header containing the suggested filename.

**Health check:** `GET http://localhost:8080/api/health` returns `ok`.

## What It Does

- Fetches any URL and strips scripts, styles, nav, footer, ads, tracking elements
- Extracts article content from `<article>`, `<main>`, or `<body>`
- Converts headings, images, links, bold/italic/underline to the chosen format
- Downloads as `.md` or `.scripta` with a timestamped filename (e.g., `grab-20260214-example-domain.md`)

## Output Format Examples

### Markdown (.md)

```
# Article Title

## Section Heading

Paragraph text with [label](https://example.com) inline links.

![alt](https://example.com/photo.jpg)

More text with **bold** and *italic* formatting.
```

### Scripta (.scripta)

```
# Article Title

## Section Heading

Paragraph text with [link label https://example.com] inline links.

| image
https://example.com/photo.jpg

More text with [b bold] and [i italic] formatting.
```
