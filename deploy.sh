#!/bin/bash
# Build and deploy to Cloudflare Pages

echo "Building site..."
stack exec site build

echo "Deploying to Cloudflare..."
wrangler pages deploy _site --project-name=jxxcarlson

echo "Done! Site live at https://jxxcarlson.org"
