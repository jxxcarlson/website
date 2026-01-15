#!/bin/bash
# Watch the Archive folder and rebuild site on changes

ARCHIVE_DIR="$HOME/Desktop/ARCHIVE"

echo "Watching $ARCHIVE_DIR for changes..."
echo "Press Ctrl+C to stop"

fswatch -o "$ARCHIVE_DIR" | while read; do
    echo "Change detected, rebuilding..."
    stack exec site build
done
