# Hancom Office Archive

Historical Hancom Office installation-media archive.

## 2014 structure

- `2014/RTM/`
- `2014/VP/`
- `2014/Viewer/`
- `2014/Mac/`
- `2014/Tools/HancomUpdate/`
- `2014/Updates/`
- `2014/WebPayload/` — recovered web-installer manifests and payload families

`manifest.tsv` and `manifest.json` record acquisition status, source URL,
file size and SHA-256.

Large binaries are published under the `2014-archive` GitHub Release rather
than committed directly to the Git tree. Recovered payload trees are bundled
with their directory structure intact because many families contain identical
basenames such as `cab1.cab`.

## Sync the recovered 2014 archive

The repository includes `tools/sync-2014-release.sh`. It compares the local
archive with existing Release assets by SHA-256, skips exact matches, uploads
new files, and stops on same-name/different-content conflicts unless
`--clobber` is explicitly requested.

```bash
brew install gh zstd
gh auth login
cd ~/Downloads/hancom-office-archive
git pull
chmod +x tools/sync-2014-release.sh
./tools/sync-2014-release.sh --dry-run
./tools/sync-2014-release.sh
```

Default local archive path: `~/Downloads/hancom-office-archive/2014`.
