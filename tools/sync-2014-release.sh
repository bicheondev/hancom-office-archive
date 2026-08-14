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

Low-disk sync of the local Hancom Office 2014 archive to GitHub Release.

Key behavior:
  * --dry-run creates NO copies and NO tar.zst bundles.
  * Unique standalone files are uploaded directly from their original path.
  * Duplicate basenames use a hard link with an encoded asset name (no duplicate data blocks).
  * Web payload families are bundled ONE AT A TIME; after upload each temporary bundle is deleted.
  * Existing assets with matching GitHub SHA-256 digests are skipped.
  * Same-name/different-digest assets abort unless --clobber is supplied.
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

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  if (( DRY_RUN )); then
    echo "[WOULD-CREATE-RELEASE] $TAG"
  else
    gh release create "$TAG" --repo "$REPO" \
      --title "Hancom Office 2014 Archive" \
      --notes "Archived Hancom Office 2014 installation media, updates, viewers, Mac packages and recovered web-install payload families."
  fi
fi

# Clean leftovers from an interrupted old run first. This is intentionally tiny in dry-run mode.
rm -rf "$WORK"
mkdir -p "$WORK"
REMOTE_JSON="$WORK/remote-release.json"
REMOTE_TSV="$WORK/remote-assets.tsv"
CANDIDATES="$WORK/candidates.bin"
COUNTS="$WORK/basename-counts.tsv"
MANIFEST="$WORK/release-assets-2014.tsv"
printf 'asset\tbytes\tsha256\tsource\tstatus\n' > "$MANIFEST"

gh api "repos/$REPO/releases/tags/$TAG" > "$REMOTE_JSON"
python3 - "$REMOTE_JSON" "$REMOTE_TSV" <<'PY'
import json, sys
src,dst=sys.argv[1:]
r=json.load(open(src,encoding='utf-8'))
with open(dst,'w',encoding='utf-8') as f:
    for a in r.get('assets',[]):
        d=a.get('digest') or ''
        if d.startswith('sha256:'): d=d[7:]
        f.write(f"{a['name']}\t{d}\t{a.get('size','')}\n")
PY

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes() { stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"; }
encoded_name() { local r="${1#./}"; r="${r//\//__}"; printf '%s' "$r"; }
remote_digest() { awk -F '\t' -v n="$1" '$1==n {print $2; exit}' "$REMOTE_TSV"; }
remote_exists() { awk -F '\t' -v n="$1" '$1==n {found=1} END {exit !found}' "$REMOTE_TSV"; }

record() {
  local name="$1" path="$2" src="$3" status="$4" sha bytes
  sha="$(sha256_file "$path")"; bytes="$(file_bytes "$path")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$bytes" "$sha" "$src" "$status" >> "$MANIFEST"
}

# Standalone media candidates. Payload contents are handled separately as bundles.
: > "$CANDIDATES"
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  case "$rel" in
    WebPayload/*|*/Payload/*) continue ;;
    *.metadata.txt|*/SHA256SUMS.txt|SHA256SUMS.txt|*.flist.txt) continue ;;
  esac
  case "$f" in
    *.exe|*.pkg|*.deb|*.rpm|*.iso|*.zip|*.msi|*.cab|*.dmg) printf '%s\0' "$f" >> "$CANDIDATES" ;;
  esac
done < <(find "$SRC" -type f -print0)

python3 - "$CANDIDATES" "$COUNTS" <<'PY'
import collections,sys
src,dst=sys.argv[1:]
paths=[x.decode() for x in open(src,'rb').read().split(b'\0') if x]
c=collections.Counter(p.rsplit('/',1)[-1] for p in paths)
with open(dst,'w',encoding='utf-8') as f:
    for n,k in sorted(c.items()): f.write(f'{n}\t{k}\n')
PY
basename_count() { awk -F '\t' -v n="$1" '$1==n {print $2; exit}' "$COUNTS"; }

same=0; new=0; diff=0
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"; base="$(basename "$f")"; count="$(basename_count "$base")"
  if [[ "${count:-1}" -eq 1 ]]; then name="$base"; else name="$(encoded_name "$rel")"; fi
  local_sha="$(sha256_file "$f")"; rd="$(remote_digest "$name")"
  if [[ -n "$rd" && "$rd" == "$local_sha" ]]; then
    echo "[OK]   $name"
    printf '%s\t%s\t%s\t%s\tOK\n' "$name" "$(file_bytes "$f")" "$local_sha" "$rel" >> "$MANIFEST"
    same=$((same+1)); continue
  fi
  if remote_exists "$name"; then
    echo "[DIFF] $name  <- $rel"
    printf '%s\t%s\t%s\t%s\tDIFF\n' "$name" "$(file_bytes "$f")" "$local_sha" "$rel" >> "$MANIFEST"
    diff=$((diff+1))
    if (( ! DRY_RUN && ! CLOBBER )); then
      echo "Refusing to replace $name without --clobber" >&2; exit 3
    fi
  else
    echo "[NEW]  $name  <- $rel"
    printf '%s\t%s\t%s\t%s\tNEW\n' "$name" "$(file_bytes "$f")" "$local_sha" "$rel" >> "$MANIFEST"
    new=$((new+1))
  fi

  if (( ! DRY_RUN )); then
    upload_path="$f"
    # gh release upload uses basename as asset name. Only make a hard link when a collision-safe name is needed.
    if [[ "$name" != "$base" ]]; then
      upload_path="$WORK/$name"
      rm -f "$upload_path"
      ln "$f" "$upload_path"
    fi
    if remote_exists "$name"; then
      gh release upload "$TAG" "$upload_path" --repo "$REPO" --clobber
    else
      gh release upload "$TAG" "$upload_path" --repo "$REPO"
    fi
    [[ "$upload_path" == "$f" ]] || rm -f "$upload_path"
  fi
done < "$CANDIDATES"

# Bundle definitions: four unique recovered payload families + manifests.
# In dry-run mode we do not create archives; this is safe even with almost no free space.
bundle_one() {
  local dir="$1" name="$2"
  [[ -d "$dir" ]] || return 1
  local src_rel="${dir#$ROOT/}/"
  if (( DRY_RUN )); then
    if remote_exists "$name"; then
      echo "[BUNDLE-REMOTE] $name  <- $src_rel (digest not rechecked in dry-run; no temp archive created)"
    else
      echo "[BUNDLE-NEW]    $name  <- $src_rel"
      new=$((new+1))
    fi
    return 0
  fi

  local out="$WORK/$name"
  echo "[BUNDLE] $src_rel -> $name"
  rm -f "$out"
  tar -C "$(dirname "$dir")" -cf - "$(basename "$dir")" | zstd -T0 -6 -q -o "$out"
  local sha rd
  sha="$(sha256_file "$out")"; rd="$(remote_digest "$name")"
  if [[ -n "$rd" && "$rd" == "$sha" ]]; then
    echo "[OK]   $name"
    record "$name" "$out" "$src_rel" "OK"
    rm -f "$out"; return 0
  fi
  if remote_exists "$name"; then
    if (( ! CLOBBER )); then
      echo "[DIFF] $name; refusing replacement without --clobber" >&2
      rm -f "$out"; exit 3
    fi
    gh release upload "$TAG" "$out" --repo "$REPO" --clobber
  else
    gh release upload "$TAG" "$out" --repo "$REPO"
  fi
  record "$name" "$out" "$src_rel" "UPLOADED"
  rm -f "$out"
}

bundle_one "$SRC/WebPayload/manifests" "2014-WebPayload-manifests.tar.zst" || true
bundle_one "$SRC/WebPayload/payloads/HOffice2014" "2014-WebPayload-HOffice2014.tar.zst" || \
  bundle_one "$SRC/VP/Standard/Payload" "2014-WebPayload-HOffice2014.tar.zst" || true
bundle_one "$SRC/WebPayload/payloads/HOffice2014_ESD" "2014-WebPayload-HOffice2014-ESD.tar.zst" || \
  bundle_one "$SRC/VP/ESD/Payload" "2014-WebPayload-HOffice2014-ESD.tar.zst" || true
bundle_one "$SRC/WebPayload/payloads/HOffice2014_HOME" "2014-WebPayload-HOffice2014-HOME.tar.zst" || \
  bundle_one "$SRC/VP/Home/Payload" "2014-WebPayload-HOffice2014-HOME.tar.zst" || true
bundle_one "$SRC/WebPayload/payloads/Hwp2014VP" "2014-WebPayload-Hwp2014VP.tar.zst" || \
  bundle_one "$SRC/VP/Hwp/Payload" "2014-WebPayload-Hwp2014VP.tar.zst" || true

echo
echo "Standalone summary: same=$same new=$new diff=$diff"
echo "Manifest: $MANIFEST"
if (( DRY_RUN )); then
  echo "DRY RUN: no media files were copied, bundled, uploaded, or replaced."
else
  # Upload the small manifest last.
  gh release upload "$TAG" "$MANIFEST" --repo "$REPO" --clobber
  echo "Release sync completed. Temporary bundles were deleted after upload."
fi
