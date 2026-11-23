#!/usr/bin/env bash
# Builds the Blazor report and publishes it to docs/ (GitHub Pages).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.dotnet:$PATH"
python3 tools/build-data.py
python3 tools/build-site.py
rm -rf /tmp/blazor-out
(cd site && dotnet publish -c Release -o /tmp/blazor-out)
cp -a /tmp/blazor-out/wwwroot/. ../docs/
# GitHub Pages cannot set Content-Encoding for precompressed files; the boot uses plain assets.
find ../docs -name '*.br' -delete
find ../docs -name '*.gz' -delete
touch ../docs/.nojekyll
echo "published to docs/ ($(du -sh ../docs/_framework | cut -f1) framework)"
