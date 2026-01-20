#!/bin/bash
# Build and deploy to Cloudflare Pages

echo "Rebuilding site..."
stack build
stack exec site rebuild


echo "Deploying to Cloudflare..."
wrangler pages deploy _site --project-name=jxxcarlson

echo "Done! Site live at https://jxxcarlson.org"
