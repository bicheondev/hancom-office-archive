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

Sync the local Hancom Office 2014 archive to the GitHub Release.

Rules:
  * Normal installer/update/viewer/package files are uploaded individually.
  * A basename is preserved when it is unique, so existing Release assets are matched.
  * If the same basename exists at multiple local paths, only then is its relative path encoded
    with '__' to make a collision-safe Release asset name.
  * Recovered web-installer payload families are preserved as tar.zst archives.
  * Existing assets with matching GitHub SHA-256 digests are skipped.
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

for cmd in gh python3 shasum tar zstd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 1; }
done

[[ -d "$SRC" ]] || { echo "Missing local archive: $SRC" >&2; exit 1; }
gh auth status >/dev/null

gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || {
  echo "Creating release $TAG"
  if (( ! DRY_RUN )); then
    gh release create "$TAG" --repo "$REPO" \
      --title "Hancom Office 2014 Archive" \
      --notes "Archived Hancom Office 2014 installation media, updates, viewers, Mac packages and recovered web-install payload families."
  fi
}

rm -rf "$WORK"
mkdir -p "$WORK/assets"
ASSET_DIR="$WORK/assets"
MANIFEST="$WORK/release-assets-2014.tsv"
printf 'asset\tbytes\tsha256\tsource\n' > "$MANIFEST"

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes() { stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"; }

record_asset() {
  local asset="$1" source="$2"
  printf '%s\t%s\t%s\t%s\n' \
    "$(basename "$asset")" "$(file_bytes "$asset")" "$(sha256_file "$asset")" "$source" >> "$MANIFEST"
}

encoded_name() {
  local rel="$1"
  rel="${rel#./}"
  rel="${rel//\//__}"
  printf '%s' "$rel"
}

# Enumerate releasable standalone files first, then count basename collisions.
CANDIDATES="$WORK/candidates.bin"
: > "$CANDIDATES"
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  case "$rel" in
    WebPayload/*|*/Payload/*) continue ;;
    *.metadata.txt|*/SHA256SUMS.txt|SHA256SUMS.txt|*.flist.txt) continue ;;
  esac
  case "$f" in
    *.exe|*.pkg|*.deb|*.rpm|*.iso|*.zip|*.msi|*.cab|*.dmg)
      printf '%s\0' "$f" >> "$CANDIDATES"
      ;;
  esac
done < <(find "$SRC" -type f -print0)

COUNTS="$WORK/basename-counts.tsv"
python3 - "$CANDIDATES" "$COUNTS" <<'PY'
import collections, sys
src, dst = sys.argv[1:]
data = open(src,'rb').read().split(b'\0')
paths = [x.decode() for x in data if x]
c = collections.Counter(p.rsplit('/',1)[-1] for p in paths)
with open(dst,'w',encoding='utf-8') as f:
    for name,count in sorted(c.items()):
        f.write(f'{name}\t{count}\n')
PY

basename_count() {
  awk -F '\t' -v n="$1" '$1==n {print $2; exit}' "$COUNTS"
}

while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  base="$(basename "$f")"
  count="$(basename_count "$base")"
  if [[ "${count:-1}" -eq 1 ]]; then
    name="$base"
  else
    name="$(encoded_name "$rel")"
  fi
  cp -p "$f" "$ASSET_DIR/$name"
  record_asset "$ASSET_DIR/$name" "$rel"
done < "$CANDIDATES"

bundle_dir() {
  local dir="$1" label="$2"
  [[ -d "$dir" ]] || return 1
  local out="$ASSET_DIR/${label}.tar.zst"
  echo "Bundling ${dir#$ROOT/} -> $(basename "$out")"
  tar -C "$(dirname "$dir")" -cf - "$(basename "$dir")" | zstd -T0 -19 -q -o "$out"
  record_asset "$out" "${dir#$ROOT/}/"
  return 0
}

# Preserve the four unique web-payload families recovered from Hancom flist manifests.
# Prefer WebPayload copies; fall back to normalized VP/Payload copies when needed.
if [[ -d "$SRC/WebPayload/manifests" ]]; then
  bundle_dir "$SRC/WebPayload/manifests" "2014-WebPayload-manifests"
fi

bundle_dir "$SRC/WebPayload/payloads/HOffice2014" "2014-WebPayload-HOffice2014" || \
  bundle_dir "$SRC/VP/Standard/Payload" "2014-WebPayload-HOffice2014" || true
bundle_dir "$SRC/WebPayload/payloads/HOffice2014_ESD" "2014-WebPayload-HOffice2014-ESD" || \
  bundle_dir "$SRC/VP/ESD/Payload" "2014-WebPayload-HOffice2014-ESD" || true
bundle_dir "$SRC/WebPayload/payloads/HOffice2014_HOME" "2014-WebPayload-HOffice2014-HOME" || \
  bundle_dir "$SRC/VP/Home/Payload" "2014-WebPayload-HOffice2014-HOME" || true
bundle_dir "$SRC/WebPayload/payloads/Hwp2014VP" "2014-WebPayload-Hwp2014VP" || \
  bundle_dir "$SRC/VP/Hwp/Payload" "2014-WebPayload-Hwp2014VP" || true

# Snapshot manifest after all real assets have been recorded.
cp "$MANIFEST" "$ASSET_DIR/release-assets-2014.tsv"

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

release = json.loads(sh('gh','api',f'repos/{repo}/releases/tags/{tag}'))
remote_assets = {a['name']: a for a in release.get('assets', [])}
local_files = sorted(
    os.path.join(asset_dir,n) for n in os.listdir(asset_dir)
    if os.path.isfile(os.path.join(asset_dir,n))
)

print(f'Local release assets: {len(local_files)}')
print(f'Existing remote assets: {len(remote_assets)}')
new = same = replaced = 0

for path in local_files:
    name = os.path.basename(path)
    local = sha256(path)
    remote = remote_assets.get(name)
    if remote:
        digest = remote.get('digest') or ''
        if digest.startswith('sha256:') and digest[7:].lower() == local.lower():
            print(f'[OK]   {name}')
            same += 1
            continue
        if not clobber:
            print(f'[DIFF] {name}: remote exists but SHA-256 differs or is unavailable.', file=sys.stderr)
            print('       Re-run with --clobber only after confirming the local file is canonical.', file=sys.stderr)
            sys.exit(3)
        print(f'[REPLACE] {name}')
        if not dry:
            subprocess.check_call(['gh','release','upload',tag,path,'--repo',repo,'--clobber'])
        replaced += 1
    else:
        print(f'[NEW]  {name}')
        if not dry:
            subprocess.check_call(['gh','release','upload',tag,path,'--repo',repo])
        new += 1

print(f'Summary: same={same} new={new} replaced={replaced} dry_run={dry}')
PY

echo
echo "Sync complete."
echo "Generated manifest: $MANIFEST"
echo "Assets staged in:     $ASSET_DIR"
if (( DRY_RUN )); then
  echo "DRY RUN only: nothing was uploaded."
else
  echo "Release: https://github.com/$REPO/releases/tag/$TAG"
fi
