
---
title: Website Constructon Notes
---



## Hakyll site structure:

```
  Website/
  ├── Site.hs              # Main Hakyll compiler
  ├── stack.yaml           # Stack resolver config (LTS 22.43)
  ├── package.yaml         # Project dependencies
  ├── index.html           # Homepage with post listing
  ├── css/
  │   └── default.css      # Stylesheet
  ├── pages/
  │   └── about.md         # About page
  ├── posts/
  │   └── 2025-01-14-hello-world.md
  ├── templates/
  │   ├── default.html     # Base layout
  │   ├── post.html        # Post template
  │   └── archive.html     # Archive listing
  └── images/              # For static images
```

  To build and run:

  - `stack build`                    # Build the site generator
  - `stack exec site build`          # Generate the site to _site/
  - `stack exec site watch`          # Dev server with live reload

  After changes to `Site.hs`:
  
  - `stack exec site rebuild`

  The site generator compiles Markdown posts and pages with Pandoc, applies templates, and outputs static HTML to _site/. Posts are dated by filename (YYYY-MM-DD-slug.md) and automatically sorted by date on the index and archive pages.
