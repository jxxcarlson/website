---
name: deploy
description: Build and deploy the website to Cloudflare Pages
---

Run the deploy script to build and deploy the site:

```bash
sh scripts/deploy.sh
```

This will:
1. Rebuild the Haskell project
2. Regenerate the site
3. Deploy to Cloudflare Pages (jxxcarlson.org)
