#!/usr/bin/env bash
# Restore Claude.app's original app.asar from the most recent backup.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/Claude.app"
ASAR="$APP/Contents/Resources/app.asar"
BACKUP_DIR="$HERE/backups"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
die()  { printf "\033[31m!!\033[0m %s\n" "$*" >&2; exit 1; }

[[ -d "$BACKUP_DIR" ]] || die "No backups directory at $BACKUP_DIR — nothing to restore."

LATEST="$(ls -t "$BACKUP_DIR"/app.asar.* 2>/dev/null | head -1)"
[[ -n "$LATEST" ]] || die "No backup files found in $BACKUP_DIR"

if pgrep -f "Claude.app/Contents/MacOS/Claude\$" >/dev/null 2>&1; then
  die "Claude is running. Quit it (Cmd+Q) and re-run this script."
fi

log "Most recent backup:  $LATEST"
log "Size / date:         $(ls -lh "$LATEST" | awk '{print $5, $6, $7, $8}')"
read -r -p "Restore this backup over $ASAR? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 0; }

log "Restoring → $ASAR"
cp -p "$LATEST" "$ASAR"

log "Re-enabling asar-integrity fuse"
npx --yes @electron/fuses write --app "$APP" \
  EnableEmbeddedAsarIntegrityValidation=on \
  >/dev/null 2>&1 || true

log "Ad-hoc re-signing bundle"
codesign --force --deep --sign - "$APP" 2>&1 | tail -3 || true

log "Clearing quarantine xattrs"
xattr -cr "$APP" 2>/dev/null || true

cat <<EOF

✅ Restored from $LATEST

   Launch Claude from the Dock — it should be back to the default theme.
   Backup left in place in case you want to reapply or inspect it.

EOF
