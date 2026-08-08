#!/usr/bin/env bash
#
# Deploy the memory MCP server to the gus droplet.
#
#   ./mcp/deploy.sh            # deploy
#   ./mcp/deploy.sh --dry-run  # show what would sync, change nothing
#
# Requires an `ssh gus` alias that lands as root. Override with GUS_SSH_HOST.
#
# WHY THIS IS AN ALLOWLIST AND NOT `rsync --delete`
#
# Until 2026-08-08 there was no deploy process here at all: /home/openclaw/mcp
# is a hand-copied directory, not a checkout. Files were edited directly on the
# host and drifted ahead of git for months -- the file_read/file_list tools ran
# in production while existing in no commit anywhere (recovered in cfde885).
#
# So this script syncs a named list of files and never deletes remote ones.
# A blanket copy would have destroyed that work, and --delete would remove the
# host's env and token files. If you add a source file, add it to FILES below;
# anything not listed is left alone on the host, deliberately.

set -euo pipefail

HOST="${GUS_SSH_HOST:-gus}"
REMOTE_DIR="/home/openclaw/mcp"
REMOTE_USER="openclaw"
UNIT="mcp-server.service"
KEEP_BACKUPS=5

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Synced to the host. Add new source files here.
FILES=(
  mcp-server.mjs
  tools.mjs
  db.mjs
  auth.mjs
  package.json
  package-lock.json
  DEPLOY-NOTES.md
  claude-mcp-config.example.json
)
DIRS=(migrations)

# NEVER synced, each for its own reason:
#   generate-tokens.sh  - drifted on the host (repo copy is older and shorter)
#                         and it mints auth tokens. Syncing would clobber the
#                         live version; the host copy is authoritative until a
#                         human reviews it. See the deploy notes.
#   mcp-server.service  - reference copy only. The live unit carries
#                         Environment=/EnvironmentFile= values that are not in
#                         git; installing this file would strip them.
#   node_modules/       - rebuilt on the host by `npm ci`.
#   .env, .env.*, env   - host-provisioned secrets. Never read, never copied.

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '\n=== %s\n' "$*"; }
run() {
  if ((DRY_RUN)); then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- preflight -------------------------------------------------------------
log "Preflight"

for f in "${FILES[@]}"; do
  [[ -f "$SRC/$f" ]] || { echo "missing source file: $SRC/$f" >&2; exit 1; }
done
for d in "${DIRS[@]}"; do
  [[ -d "$SRC/$d" ]] || { echo "missing source dir: $SRC/$d" >&2; exit 1; }
done

ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" true \
  || { echo "cannot ssh to '$HOST'" >&2; exit 1; }

ssh "$HOST" "test -d '$REMOTE_DIR'" \
  || { echo "remote dir $REMOTE_DIR missing -- this script updates an existing deploy, it does not bootstrap one" >&2; exit 1; }

ssh "$HOST" "systemctl cat '$UNIT' >/dev/null 2>&1" \
  || { echo "unit $UNIT not found on $HOST" >&2; exit 1; }

echo "  host=$HOST dir=$REMOTE_DIR unit=$UNIT"
echo "  node=$(ssh "$HOST" '/usr/bin/node --version')"

# --- backup ----------------------------------------------------------------
# Source and manifests only. node_modules is excluded: it is large, and `npm ci`
# reproduces it exactly from the lockfile we are about to ship.
log "Backup"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${REMOTE_DIR}.bak-${STAMP}"

run ssh "$HOST" "
  set -euo pipefail
  mkdir -p '$BACKUP'
  cd '$REMOTE_DIR'
  for item in *.mjs *.json *.md *.sh migrations; do
    [ -e \"\$item\" ] && cp -a \"\$item\" '$BACKUP'/ || true
  done
  chown -R $REMOTE_USER:$REMOTE_USER '$BACKUP'
"
echo "  backup: $BACKUP"

# Keep the most recent KEEP_BACKUPS, so repeat runs don't fill the disk.
run ssh "$HOST" "
  set -euo pipefail
  ls -1dt ${REMOTE_DIR}.bak-* 2>/dev/null | tail -n +\$(( $KEEP_BACKUPS + 1 )) | xargs -r rm -rf
"

# --- sync ------------------------------------------------------------------
log "Sync source"

RSYNC_OPTS=(-az --checksum --no-perms --no-owner --no-group)
((DRY_RUN)) && RSYNC_OPTS+=(--dry-run --itemize-changes)

rsync "${RSYNC_OPTS[@]}" \
  "${FILES[@]/#/$SRC/}" \
  "$HOST:$REMOTE_DIR/"

for d in "${DIRS[@]}"; do
  rsync "${RSYNC_OPTS[@]}" "$SRC/$d/" "$HOST:$REMOTE_DIR/$d/"
done

run ssh "$HOST" "chown -R $REMOTE_USER:$REMOTE_USER '$REMOTE_DIR'"

# --- dependencies ----------------------------------------------------------
# `npm ci` rather than `npm install`: it installs exactly the lockfile, which is
# what makes the deployed tree auditable against the repo.
log "Install dependencies (npm ci)"

run ssh "$HOST" "
  cd '$REMOTE_DIR'
  sudo -u $REMOTE_USER -H env HOME=/home/$REMOTE_USER npm ci --no-audit --no-fund
"

# --- restart ---------------------------------------------------------------
log "Restart $UNIT"

run ssh "$HOST" "systemctl restart '$UNIT'"
run sleep 4

# --- verify ----------------------------------------------------------------
log "Verify"

if ((DRY_RUN)); then
  echo "  [dry-run] skipped"
  exit 0
fi

if ! ssh "$HOST" "systemctl is-active --quiet '$UNIT'"; then
  echo "FAILED: $UNIT is not active after restart" >&2
  ssh "$HOST" "systemctl status '$UNIT' --no-pager -n 20" >&2 || true
  echo "Roll back with: ssh $HOST \"cp -a $BACKUP/. $REMOTE_DIR/ && systemctl restart $UNIT\"" >&2
  exit 1
fi

ssh "$HOST" "systemctl show '$UNIT' -p ActiveState -p SubState -p MainPID -p NRestarts"

# Journal since the restart. Long tokens are scrubbed before display -- the
# server logs user identifiers rather than credentials, but this file must be
# safe to run with someone watching the terminal.
log "Journal (last 20 lines, tokens scrubbed)"
ssh "$HOST" "journalctl -u '$UNIT' -n 20 --no-pager --since '2 minutes ago'" \
  | sed -E 's/[A-Za-z0-9_-]{28,}/[REDACTED]/g'

if ssh "$HOST" "journalctl -u '$UNIT' --since '2 minutes ago' --no-pager" \
     | grep -qiE 'error|exception|ECONNREFUSED|Cannot find module|unhandled'; then
  echo
  echo "WARNING: error-like lines in the journal since restart -- check above." >&2
  exit 1
fi

log "Deployed cleanly"
echo "  $UNIT active on $HOST"
echo "  backup retained at $BACKUP"
