#!/bin/bash
# Watch /Users/carlson/Desktop/ARCHIVE and trigger refresh.sh on changes

WATCH_DIR="/Users/carlson/Desktop/ARCHIVE"
LAST_HASH=""

echo "Watching $WATCH_DIR for changes (checking every 5 seconds)..."

while true; do
    # Get hash of file modification times
    CURRENT_HASH=$(find "$WATCH_DIR" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort | md5)
    
    if [ "$LAST_HASH" != "" ] && [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        echo "$(date): Change detected, rebuilding..."
        stack exec site rebuild
    fi
    
    LAST_HASH="$CURRENT_HASH"
    sleep 5
done
