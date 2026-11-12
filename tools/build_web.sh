#!/bin/bash
# Production Web build: writes the ranking API address into scripts/api_config.gd only for the
# export, exports to build/web-prod, puts the file back, and prints the build's file manifest.
# It uses the export preset "WebProd", which leaves the diagnostic overlay (scripts/diag.gd) out.
# The verifier must run this same build (node server/verifier.mjs --build-dir build/web-prod).
#   tools/build_web.sh https://countershift-ranking.<subdomain>.workers.dev [name]
# name: folder under build/ (default web-prod). Use another name for a trial build so that the
# published build, which the verifier runs, is not replaced.
set -euo pipefail
API="${1:-}"
case "$API" in
  https://*) ;;
  http://127.0.0.1:*|http://localhost:*) echo "note: local API address (test build)";;
  *) echo "usage: tools/build_web.sh https://<ranking api>" >&2; exit 2;;
esac
API="${API%/}"
OUT="${2:-web-prod}"
case "$OUT" in web|*/*|.*|"") echo "bad build name" >&2; exit 2;; esac
cd "$(dirname "$0")/.."
GODOT="${GODOT:-$HOME/Downloads/Godot.app/Contents/MacOS/Godot}"
CFG=scripts/api_config.gd
BACKUP="$(mktemp)"
cp "$CFG" "$BACKUP"
restore() { cp "$BACKUP" "$CFG"; rm -f "$BACKUP"; }
trap restore EXIT
sed -i '' "s|^const URL := \".*\"|const URL := \"$API\"|" "$CFG"
grep -q "const URL := \"$API\"" "$CFG" || { echo "could not write $CFG" >&2; exit 1; }
touch build/.gdignore          # Godot must not scan (and add .import files to) the builds
rm -rf "build/$OUT"
mkdir -p "build/$OUT"
"$GODOT" --headless --path . --export-release "WebProd" build/$OUT/index.html > build/$OUT.log 2>&1 || { tail -20 build/$OUT.log; exit 1; }
grep -q "DONE.*savepack\|savepack.*DONE" build/$OUT.log || grep -q "savepack" build/$OUT.log
cp fonts/NotoSansJP-LICENSE.txt build/$OUT/
rm -f "build/countershift-$OUT.zip"
(cd "build/$OUT" && zip -q -r "../countershift-$OUT.zip" .)
restore
trap - EXIT
git diff --quiet -- "$CFG" || { echo "warning: $CFG differs from git" >&2; }
node -e 'import("./server/verifier.mjs").then(m => console.log("build/" + process.argv[1].slice(6) + " files " + m.buildManifest(process.argv[1])))' "build/$OUT"
echo "API: $API"
echo "zip: build/countershift-$OUT.zip"
