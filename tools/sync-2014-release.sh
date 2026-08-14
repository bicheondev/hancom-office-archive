#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-bicheondev/hancom-office-archive}"
TAG="${TAG:-2014-archive}"
ROOT="${ROOT:-$HOME/Downloads/hancom-office-archive}"
SRC="$ROOT/2014"
WORK="${WORK:-$ROOT/.release-sync-2014}"
DRY_RUN=0
CLOBBER=0

usage() {
  cat <<'EOF'
Usage: tools/sync-2014-release.sh [--root PATH] [--repo OWNER/REPO] [--tag TAG] [--dry-run] [--clobber]

Sync locally archived Hancom Office 2014 media to a GitHub Release.

Strategy:
  * Standalone top-level installer/update files are uploaded as individual assets.
  * Payload trees and other directories with duplicate basenames are archived as tar.zst bundles.
  * Every uploaded asset gets a local SHA-256 row in release-assets-2014.tsv.
  * Existing release assets are skipped when their SHA-256 digest matches.
  * Same-name/different-digest assets abort unless --clobber is explicitly supplied.

Defaults:
  ROOT=$HOME/Downloads/hancom-office-archive
  REPO=bicheondev/hancom-office-archive
  TAG=2014-archive
EOF
}

while (($#)); do
  case "$1" in
    --root) ROOT="$2"; SRC="$ROOT/2014"; WORK="$ROOT/.release-sync-2014"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --clobber) CLOBBER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for cmd in gh python3 shasum tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 1; }
done

if command -v zstd >/dev/null 2>&1; then
  COMPRESSOR=zstd
else
  echo "zstd is required. Install it first (for example: brew install zstd)." >&2
  exit 1
fi

[[ -d "$SRC" ]] || { echo "Missing local archive: $SRC" >&2; exit 1; }
gh auth status >/dev/null

gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || {
  echo "Creating release $TAG"
  if (( ! DRY_RUN )); then
    gh release create "$TAG" --repo "$REPO" --title "Hancom Office 2014 Archive" --notes "Archived Hancom Office 2014 installation media, updates, viewers, Mac packages and recovered web-install payload families."
  fi
}

rm -rf "$WORK"
mkdir -p "$WORK/assets"
ASSET_DIR="$WORK/assets"
MANIFEST="$WORK/release-assets-2014.tsv"
printf 'asset\tbytes\tsha256\tsource\n' > "$MANIFEST"

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

record_asset() {
  local asset="$1" source="$2" sha bytes
  sha="$(sha256_file "$asset")"
  bytes="$(stat -f '%z' "$asset" 2>/dev/null || stat -c '%s' "$asset")"
  printf '%s\t%s\t%s\t%s\n' "$(basename "$asset")" "$bytes" "$sha" "$source" >> "$MANIFEST"
}

# Build a release-safe asset name from a relative path.
encoded_name() {
  local rel="$1"
  rel="${rel#./}"
  rel="${rel//\//__}"
  printf '%s' "$rel"
}

# Copy standalone media files. Metadata/checksum text stays in Git itself.
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  case "$rel" in
    WebPayload/*|*/Payload/*) continue ;;
    *.metadata.txt|*/SHA256SUMS.txt|SHA256SUMS.txt|*.flist.txt) continue ;;
  esac
  case "$f" in
    *.exe|*.pkg|*.deb|*.rpm|*.iso|*.zip|*.msi|*.cab|*.dmg)
      name="$(encoded_name "$rel")"
      cp -p "$f" "$ASSET_DIR/$name"
      record_asset "$ASSET_DIR/$name" "$rel"
      ;;
  esac
done < <(find "$SRC" -type f -print0)

# Canonical payload families. RTM and VP web manifests proved several pairs identical;
# we preserve the recovered WebPayload families as their own bundles and also bundle
# normalized VP Payload trees when present.
bundle_dir() {
  local dir="$1" label="$2"
  [[ -d "$dir" ]] || return 0
  local out="$ASSET_DIR/${label}.tar.zst"
  echo "Bundling ${dir#$ROOT/} -> $(basename "$out")"
  tar -C "$(dirname "$dir")" -cf - "$(basename "$dir")" | zstd -T0 -19 -q -o "$out"
  record_asset "$out" "${dir#$ROOT/}/"
}

for d in \
  "$SRC/WebPayload/manifests" \
  "$SRC/WebPayload/payloads/HOffice2014" \
  "$SRC/WebPayload/payloads/HOffice2014_ESD" \
  "$SRC/WebPayload/payloads/HOffice2014_HOME" \
  "$SRC/WebPayload/payloads/Hwp2014VP" \
  "$SRC/VP/Standard/Payload" \
  "$SRC/VP/ESD/Payload" \
  "$SRC/VP/Home/Payload" \
  "$SRC/VP/Hwp/Payload"; do
  [[ -d "$d" ]] || continue
  label="2014-$(echo "${d#$SRC/}" | tr '/' '-' | tr ' ' '_')"
  bundle_dir "$d" "$label"
done

# Preserve full directory trees that may contain colliding filenames or historical duplicates.
for pair in \
  "Mac|2014-Mac" \
  "Viewer|2014-Viewer" \
  "Updates|2014-Updates"; do
  rel="${pair%%|*}"; label="${pair##*|}"
  bundle_dir "$SRC/$rel" "$label"
done

# Include the release manifest itself as an asset.
cp "$MANIFEST" "$ASSET_DIR/release-assets-2014.tsv"
record_asset "$ASSET_DIR/release-assets-2014.tsv" "generated"

python3 - "$REPO" "$TAG" "$ASSET_DIR" "$CLOBBER" "$DRY_RUN" <<'PY'
import hashlib, json, os, subprocess, sys
repo, tag, asset_dir, clobber_s, dry_s = sys.argv[1:]
clobber = clobber_s == '1'
dry = dry_s == '1'

def sh(*args):
    return subprocess.check_output(args, text=True)

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

raw = sh('gh','api',f'repos/{repo}/releases/tags/{tag}')
release = json.loads(raw)
assets = {a['name']: a for a in release.get('assets', [])}

files = sorted(os.path.join(asset_dir, n) for n in os.listdir(asset_dir) if os.path.isfile(os.path.join(asset_dir,n)))
print(f'Local release assets: {len(files)}')
print(f'Existing remote assets: {len(assets)}')

for path in files:
    name = os.path.basename(path)
    local = sha256(path)
    remote = assets.get(name)
    if remote:
        digest = remote.get('digest') or ''
        if digest.startswith('sha256:') and digest[7:].lower() == local.lower():
            print(f'[OK]   {name}')
            continue
        if not clobber:
            print(f'[DIFF] {name}: remote exists but digest differs/unknown; use --clobber to replace', file=sys.stderr)
            sys.exit(3)
        print(f'[REPLACE] {name}')
        if not dry:
            subprocess.check_call(['gh','release','upload',tag,path,'--repo',repo,'--clobber'])
    else:
        print(f'[NEW]  {name}')
        if not dry:
            subprocess.check_call(['gh','release','upload',tag,path,'--repo',repo])
PY

echo
echo "Sync complete."
echo "Generated manifest: $MANIFEST"
echo "Assets staged in:     $ASSET_DIR"
echo
if (( DRY_RUN )); then
  echo "DRY RUN only: nothing was uploaded."
else
  echo "Release: https://github.com/$REPO/releases/tag/$TAG"
fi
