#!/usr/bin/env bash
# Persistently inject the Neon Dusk theme into Claude.app by patching its app.asar.
# Idempotent — safe to re-run after Claude auto-updates.
#
# What it does:
#   1. Backs up the current app.asar to ./backups/app.asar.<timestamp>
#   2. Extracts app.asar, appends <style> to every HTML file in it, repacks
#   3. Disables the Electron asar-integrity fuse (so the modified asar loads)
#   4. Ad-hoc re-signs the bundle (modified contents break the original signature)
#   5. Clears quarantine xattrs so Gatekeeper doesn't nag
#
# Rollback:   ./uninstall.sh  (restores from most recent backup)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSS_FILE="${THEME_CSS:-$HERE/neon-dusk.css}"
APP="/Applications/Claude.app"
RES="$APP/Contents/Resources"
ASAR="$RES/app.asar"
BACKUP_DIR="$HERE/backups"
STYLE_ID="neon-dusk-theme"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="$BACKUP_DIR/app.asar.$TS"
WORK="$(mktemp -d -t claude-asar.XXXXXX)"
NEW_ASAR="$WORK/app.asar.new"

log()   { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m==>\033[0m %s\n" "$*" >&2; }
die()   { printf "\033[31m!!\033[0m %s\n" "$*" >&2; exit 1; }

cleanup() { [[ -d "$WORK" ]] && rm -rf "$WORK"; }
rollback() {
  warn "Patch failed mid-flight. Rolling back from $BACKUP"
  if [[ -f "$BACKUP" ]]; then
    cp -p "$BACKUP" "$ASAR"
    warn "Restored original app.asar."
  fi
  cleanup
  exit 1
}
trap cleanup EXIT
trap rollback ERR

# --- Preflight --------------------------------------------------
[[ -d "$APP" ]]   || die "Claude not found at $APP"
[[ -f "$ASAR" ]]  || die "app.asar not found at $ASAR"
[[ -f "$CSS_FILE" ]] || die "CSS file not found at $CSS_FILE"
command -v node >/dev/null || die "node not found (install via 'brew install node')"
command -v npx  >/dev/null || die "npx not found"
command -v codesign >/dev/null || die "codesign not found (Xcode CLT required)"

if pgrep -f "Claude.app/Contents/MacOS/Claude\$" >/dev/null 2>&1; then
  die "Claude is running. Quit it (Cmd+Q) and re-run this script."
fi

# --- 1. Backup --------------------------------------------------
mkdir -p "$BACKUP_DIR"
log "Backing up current app.asar → $BACKUP"
cp -p "$ASAR" "$BACKUP"

# --- 2. Extract -------------------------------------------------
log "Extracting app.asar → $WORK/extracted"
npx --yes @electron/asar extract "$ASAR" "$WORK/extracted"

# --- 3. Find HTML files to patch -------------------------------
# Claude's renderer HTML usually lives at the root or one level deep.
# Patch every .html we find — the <style> is scoped by id so re-running is idempotent.
HTML_FILES=()
while IFS= read -r -d '' f; do
  HTML_FILES+=("$f")
done < <(find "$WORK/extracted" -type f -name "*.html" -not -path "*/node_modules/*" -print0)
[[ ${#HTML_FILES[@]} -gt 0 ]] || die "No HTML files found inside app.asar — Claude's packaging may have changed."

log "Found ${#HTML_FILES[@]} HTML file(s) to patch:"
for f in "${HTML_FILES[@]}"; do
  printf "     %s\n" "${f#$WORK/extracted/}"
done

# --- 4. Inject <style> block -----------------------------------
log "Injecting <style id=$STYLE_ID> into HTML files"

# Write the style block to a temp file (avoids bash 3.2 quirks with nested heredocs).
STYLE_FILE="$WORK/style_block.html"
python3 - "$CSS_FILE" "$STYLE_ID" "$STYLE_FILE" <<'PY'
import sys
css_path, sid, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
css = open(css_path).read()
with open(out_path, "w") as f:
    f.write(f'<style id="{sid}">\n{css}\n</style>')
PY

for f in "${HTML_FILES[@]}"; do
  python3 - "$f" "$STYLE_ID" "$STYLE_FILE" <<'PY'
import sys, re, pathlib
path, sid, block_path = sys.argv[1], sys.argv[2], sys.argv[3]
block = open(block_path).read()
p = pathlib.Path(path)
html = p.read_text()
# Strip any previous injection (idempotent).
html = re.sub(rf'<style id="{sid}">.*?</style>\s*', '', html, flags=re.DOTALL)
# Insert before </head> (case-insensitive). If no </head>, append at end.
if re.search(r'</head>', html, flags=re.IGNORECASE):
    html = re.sub(r'</head>', block + '\n</head>', html, count=1, flags=re.IGNORECASE)
else:
    html = html + '\n' + block
p.write_text(html)
print(f"     patched: {path}")
PY
done

# --- 4b. Append CSS injector to main process JS ----------------
# The shell HTML is just the window chrome — the actual chat UI is loaded
# from claude.ai into the window's WebContents. To style that, we hook the
# main process and call webContents.insertCSS() on every page that loads.
log "Appending webContents.insertCSS() injector to main process"
MAIN_ENTRY="$(python3 -c "import json; print(json.load(open('$WORK/extracted/package.json'))['main'])")"
MAIN_FILE="$WORK/extracted/$MAIN_ENTRY"
[[ -f "$MAIN_FILE" ]] || die "Main entry JS not found at $MAIN_FILE"

python3 - "$MAIN_FILE" "$CSS_FILE" <<'PY'
import sys, re, json
main_path, css_path = sys.argv[1], sys.argv[2]
css = open(css_path).read()
with open(main_path) as f:
    content = f.read()

# Strip any previous injection — sentinel markers make us idempotent.
content = re.sub(
    r'\n?/\* __NEON_DUSK_INJECTOR_BEGIN__ \*/.*?/\* __NEON_DUSK_INJECTOR_END__ \*/\n?',
    '',
    content,
    flags=re.DOTALL,
)

injector = (
    "\n/* __NEON_DUSK_INJECTOR_BEGIN__ */\n"
    ";(function(){\n"
    "  try {\n"
    "    var e = require('electron');\n"
    "    var CSS = " + json.dumps(css) + ";\n"
    "    var ATTACHED = '__neonDuskAttached';\n"
    "    var KEY = '__neonDuskKey';\n"
    "    var attach = function(wc) {\n"
    "      if (!wc || wc[ATTACHED]) return;\n"
    "      wc[ATTACHED] = true;\n"
    "      var apply = function() {\n"
    "        try {\n"
    "          if (wc[KEY]) { try { wc.removeInsertedCSS(wc[KEY]); } catch(_){}; wc[KEY] = null; }\n"
    "          var p = wc.insertCSS(CSS);\n"
    "          if (p && p.then) p.then(function(k){ wc[KEY] = k; }).catch(function(){});\n"
    "        } catch(_) {}\n"
    "      };\n"
    "      wc.on('dom-ready', apply);\n"
    "      wc.on('did-navigate', function(){ wc[KEY] = null; apply(); });\n"
    "      apply();\n"
    "    };\n"
    "    e.app.whenReady().then(function(){\n"
    "      e.app.on('web-contents-created', function(_ev, wc){ attach(wc); });\n"
    "      var wins = e.BrowserWindow.getAllWindows();\n"
    "      for (var i = 0; i < wins.length; i++) attach(wins[i].webContents);\n"
    "    }).catch(function(){});\n"
    "  } catch (err) {\n"
    "    try { console.error('[neon-dusk] injector install failed', err); } catch(_) {}\n"
    "  }\n"
    "})();\n"
    "/* __NEON_DUSK_INJECTOR_END__ */\n"
)

content = content.rstrip() + injector
with open(main_path, "w") as f:
    f.write(content)
print("     injector appended to " + main_path)
PY

# --- 5. Repack asar --------------------------------------------
log "Repacking asar → $NEW_ASAR"
# Preserve the same unpacked rules the original used (heuristic: keep *.node).
npx --yes @electron/asar pack "$WORK/extracted" "$NEW_ASAR" --unpack "*.node"

# --- 6. Install patched asar -----------------------------------
log "Installing patched asar to $ASAR"
# Atomic replace to avoid a half-written state.
mv "$NEW_ASAR" "$ASAR"

# --- 7. Disable asar integrity fuse ----------------------------
# Electron's EnableEmbeddedAsarIntegrityValidation fuse enforces a SHA256
# check on app.asar's header. If it's on, our modified asar will be rejected.
# Flipping the fuse is simpler than recomputing the hash in Info.plist.
log "Disabling asar-integrity fuse (if enabled)"
npx --yes @electron/fuses write --app "$APP" \
  EnableEmbeddedAsarIntegrityValidation=off \
  OnlyLoadAppFromAsar=on \
  >/dev/null 2>&1 || warn "fuses write returned non-zero — may be harmless"

# --- 8. Ad-hoc re-sign -----------------------------------------
log "Ad-hoc re-signing bundle (originals invalidated by modification)"
codesign --force --deep --sign - "$APP" 2>&1 | tail -5 || warn "codesign reported issues"

# --- 9. Clear quarantine --------------------------------------
log "Clearing quarantine xattrs"
xattr -cr "$APP" 2>/dev/null || true

# --- Done ------------------------------------------------------
trap - ERR
cat <<EOF

✅ Neon Dusk theme applied.

   Launch Claude from the Dock as normal — the theme loads automatically.

   CSS source:  $CSS_FILE
   Backup:      $BACKUP
   Uninstall:   $HERE/uninstall.sh

   ⚠️  Claude auto-updates will wipe this patch. Re-run this script after updates.

EOF
