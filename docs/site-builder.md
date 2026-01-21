# Site Builder Distribution Plan

Notes on making this Hakyll-based website builder accessible to non-developers.

## Goals

- Fixed structure (routes, templates) with configurable settings
- Simple command interface for common operations
- Pre-built binaries (no Haskell toolchain required)
- Easy installation

## 1. CLI Interface

Extend the Hakyll executable or create a wrapper with user-friendly commands:

```
mysite init           # Create new site from template
mysite start          # Run dev server
mysite build          # Build without serving
mysite deploy         # Build and deploy
mysite convert-images # Convert PNG/JPG to WebP
```

## 2. Configuration File

A `site.yaml` in the project root:

```yaml
title: "My Site"
author: "Name"
url: "https://example.com"
archive_path: "/Users/me/ARCHIVE"
cloudflare_project: "my-site"
```

The Haskell code would read this instead of hardcoded values.

## 3. Binary Distribution

- Build for macOS (Intel + ARM), Linux, possibly Windows
- GitHub Actions can automate multi-platform builds
- Distribution options:
  - GitHub Releases (direct download)
  - Homebrew tap for macOS (`brew install yourname/tap/mysite`)
  - curl-pipe-sh installer script

## 4. Installer

Would need to:

- Download the correct binary for the platform
- Install to `/usr/local/bin` or similar
- Install `cwebp` dependency (or bundle it)
- Optionally install shell completions

## 5. Template System

Bundle the default templates, CSS, and directory structure so `mysite init` can scaffold a new project.

## 6. Cloudflare Setup

This is potentially the hardest part for non-developers:

- User needs a Cloudflare account
- Must install wrangler CLI
- Must authenticate (`wrangler login`)
- Must create a Pages project (or the tool could do this via API)

Possible approaches to simplify:

- **Guided setup wizard**: `mysite setup-deploy` walks through the process
- **Alternative hosts**: Support simpler options like Netlify, GitHub Pages, or rsync to a server
- **Cloudflare API integration**: Tool creates the project automatically after user provides API token
- **Detailed documentation**: Step-by-step guide with screenshots

## Challenges

- Haskell binaries can be large (~50MB+)
- Cross-compilation is tricky; CI builds are easier
- External dependencies (cwebp, wrangler) add complexity
- Cloudflare authentication requires manual user action

## Potential Alternatives to Consider

- **Docker image**: Avoids binary distribution issues, but requires Docker
- **Nix flake**: Good for reproducibility, but niche audience
- **Web-based builder**: Host a service that builds and deploys for users (more complex)

## Next Steps

1. Decide on target audience and acceptable complexity
2. Choose deployment platform(s) to support
3. Design the configuration schema
4. Implement CLI commands in Haskell
5. Set up GitHub Actions for binary builds
6. Create installer script
7. Write user documentation
