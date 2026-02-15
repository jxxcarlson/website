#!/bin/sh
# Preview an archive file in the browser
# Usage: sh scripts/preview.sh FILENAME.txt
#   or:  sh scripts/preview.sh   (opens file listing)

if [ -z "$1" ]; then
    open "http://localhost:8080/api/preview"
else
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))")
    open "http://localhost:8080/api/preview?file=$encoded"
fi
