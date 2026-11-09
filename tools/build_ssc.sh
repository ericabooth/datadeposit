#!/bin/sh
# Build the flat SSC submission folder and zip: exactly the files the .pkg lists,
# nothing else (no .pkg, no stata.toc), as SSC stores every file flat.
# Run from the repository root:  sh tools/build_ssc.sh
set -e
out=dist/ssc/datadeposit
rm -rf dist/ssc
mkdir -p "$out"
grep '^f ' datadeposit.pkg | cut -c3- | while read -r f; do cp "$f" "$out/"; done
(cd dist/ssc && zip -qr datadeposit.zip datadeposit)
ls -l "$out" dist/ssc/datadeposit.zip
