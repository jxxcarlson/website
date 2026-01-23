#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_DIR="${ARCHIVE_DIR:-/Users/carlson/Dropbox/theARCHIVE}"
SITE_DIR="${SITE_DIR:-/Users/carlson/dev/website/Website}"

# Minimum time between deploys (seconds)
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-60}"

# Poll interval (seconds) for checking "dirty" status
CHECK_EVERY_SECONDS="${CHECK_EVERY_SECONDS:-10}"

# Logging with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Patterns to ignore (Dropbox temp files, editor swap files, etc.)
FSWATCH_EXCLUDES=(
  "\\.swp$"
  "\\.tmp$"
  "~$"
  "/\\.dropbox.*"
  "/\\.DS_Store$"
  "/\\.git/"
  "/\\.Trash/"
)

cd "$SITE_DIR"

# Use fixed paths so multiple instances share state
export dirty_flag="/tmp/archive_watcher_dirty"
export last_deploy_file="/tmp/archive_watcher_lastdeploy"

rm -f "$dirty_flag"  # Start clean
date +%s > "$last_deploy_file"

cleanup() {
  rm -f "$dirty_flag"
}
trap cleanup EXIT

# Mark dirty whenever fswatch reports a change
watch_changes() {
  local args=()
  for pat in "${FSWATCH_EXCLUDES[@]}"; do
    args+=(--exclude "$pat")
  done

  fswatch -r --event=Updated --event=Created --event=Removed --event=Renamed \
    "${args[@]}" \
    "$ARCHIVE_DIR" \
  | while read -r changed_file; do
      log "File changed: $changed_file"
      touch "$dirty_flag"
    done
}

rebuild_and_deploy() {
  log "Converting images to WebP..."
  sh scripts/convert-images.sh

  log "Building site..."
  stack build
  stack exec site rebuild

  log "Deploying to Cloudflare..."
  wrangler pages deploy _site --project-name=jxxcarlson
  log "Deploy complete."
}

# Main loop: check dirty flag; enforce cooldown; avoid pointless rebuilds
main_loop() {
  while true; do
    sleep "$CHECK_EVERY_SECONDS"

    # If not dirty, continue
    if [[ ! -e "$dirty_flag" ]]; then
      continue
    fi

    local now last_deploy elapsed
    now="$(date +%s)"
    last_deploy="$(cat "$last_deploy_file")"
    elapsed="$(( now - last_deploy ))"

    # Enforce cooldown: do not rebuild/deploy too frequently
    if (( elapsed < COOLDOWN_SECONDS )); then
      continue
    fi

    # Clear dirty flag optimistically; if more changes happen during build,
    # fswatch will set it again and we'll pick it up next cycle.
    rm -f "$dirty_flag"

    log "Changes detected; running rebuild+deploy."
    rebuild_and_deploy
    date +%s > "$last_deploy_file"
  done
}

# Run watcher in background and main loop in foreground
log "Starting watcher on $ARCHIVE_DIR (cooldown: ${COOLDOWN_SECONDS}s)"
watch_changes &
log "Watcher started, entering main loop..."
main_loop

