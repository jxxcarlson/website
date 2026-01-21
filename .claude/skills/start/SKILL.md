---
name: start
description: Start the development server with live reload
---

Start the Hakyll development server:

```bash
stack exec site watch
```

This starts a local server at http://localhost:8000 that automatically rebuilds when files change.

Note: To also watch the archive directory for changes, run `/watch-archive` in a separate terminal.
