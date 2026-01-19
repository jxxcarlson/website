#!/bin/bash
# Build and deploy to Cloudflare Pages

echo "Rebuilding site..."
stack exec site rebuild
# stack buildq

echo "Deploying to Cloudflare..."
wrangler pages deploy _site --project-name=jxxcarlson

echo "Done! Site live at https://jxxcarlson.org"
