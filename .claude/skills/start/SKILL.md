---
name: start
description: Start the development server with live reload
---

Start the Hakyll development server:

```bash
sh scripts/refresh.sh
```

This will:
1. Kill any existing process on port 8000
2. Convert any PNG/JPG images to WebP format
3. Build the Haskell project
4. Regenerate the site
5. Start the watch server at http://localhost:8000 with live reload

Note: To also watch the archive directory for changes, run `/watch-archive` in a separate terminal.
