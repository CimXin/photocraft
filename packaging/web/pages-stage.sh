#!/usr/bin/env bash
# Turn the static site from packaging/web/package.sh into a directory GitHub Pages
# can publish. Does not build the wasm; run package.sh first (or --self-test).
#
# Usage:
#   packaging/web/pages-stage.sh [site-dir]
#   packaging/web/pages-stage.sh --self-test
#
# With no arguments, uses the single photocraft-web-* directory under
# $CARGO_TARGET_DIR/web-package (the directory package.sh leaves beside the zip).
# Prints that directory's absolute path on stdout. Details: packaging/web/README.md.
set -euo pipefail
# shellcheck source=../env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
HERE="$ROOT/packaging/web"

# Copy every file matching the globs. An unmatched glob is an error, so a renamed
# license file cannot vanish from the published site unnoticed.
copy_licenses() {
  local dest="$1" f matched
  mkdir -p "$dest"
  matched=0
  for f in "$ROOT"/assets/fonts/OFL-*.txt \
           "$ROOT"/assets/icons/LICENSE-*.txt \
           "$ROOT"/assets/dict/LICENSE-*.txt \
           "$ROOT"/crates/ui-egui/src/i18n/LICENSE-translations.txt \
           "$ROOT"/docs/brand/LICENSE-brand.txt; do
    if [ ! -f "$f" ]; then
      echo "error: license file missing: $f" >&2
      return 1
    fi
    cp "$f" "$dest/"
    matched=$((matched + 1))
  done
  [ "$matched" -gt 0 ] || { echo "error: no license files copied" >&2; return 1; }
}

# $1 is the site directory package.sh produced (index.html at its root).
stage() {
  local site="$1" f brand
  [ -f "$site/index.html" ] || { echo "error: $site/index.html missing; run packaging/web/package.sh first" >&2; return 1; }
  # Same rule as package.sh: relative URLs, so the site works under /photocraft/.
  if grep -Eq '(src|href)="/[^/]' "$site/index.html"; then
    echo "error: $site/index.html has root-absolute URLs; it would break when served from /photocraft/" >&2
    return 1
  fi

  for f in LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md; do
    [ -f "$ROOT/$f" ] || { echo "error: $ROOT/$f missing" >&2; return 1; }
    cp "$ROOT/$f" "$site/"
  done
  if [ ! -f "$site/HOSTING.md" ]; then
    cp "$HERE/README.md" "$site/HOSTING.md"
  fi
  copy_licenses "$site/licenses" || return 1

  # copy_docs puts the repository README here. That file embeds the ArtCraft
  # wordmarks. A published fork must not ship those marks or use them as the
  # page's identity. index.html is the app; README.txt is the plain-text notice.
  rm -f "$site/README.md"
  cp "$HERE/pages-readme.txt" "$site/README.txt"
  rm -rf "$site/docs/brand"
  while IFS= read -r brand; do
    rm -f "$brand"
  done < <(find "$site" -type f \( -iname '*artcraft-logo*' -o -iname '*artcraft-mark*' \))

  : >"$site/.nojekyll"

  for f in index.html HOSTING.md README.txt LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md .nojekyll \
           favicon.ico favicon-32.png apple-touch-icon.png \
           licenses/LICENSE-brand.txt licenses/OFL-Inter.txt licenses/OFL-JetBrainsMono.txt \
           licenses/LICENSE-lucide.txt licenses/LICENSE-SCOWL.txt licenses/LICENSE-translations.txt; do
    [ -f "$site/$f" ] || { echo "error: staged site is missing $f" >&2; return 1; }
  done
  if ! grep -q 'href="favicon.ico"' "$site/index.html" || ! grep -q 'rel="apple-touch-icon"' "$site/index.html"; then
    echo "error: index.html does not link the favicon" >&2
    return 1
  fi
  if [ -d "$site/docs/brand" ]; then
    echo "error: docs/brand is still in the staged site" >&2
    return 1
  fi
  brand=$(find "$site" -type f \( -iname '*artcraft-logo*' -o -iname '*artcraft-mark*' \) | wc -l | tr -d ' ')
  [ "$brand" -eq 0 ] || { echo "error: ArtCraft brand assets are still in the staged site" >&2; return 1; }
  if grep -q 'docs/brand/' "$site/README.txt"; then
    echo "error: README.txt points at docs/brand/" >&2
    return 1
  fi
  if grep -Eq '<img[[:space:]]' "$site/README.txt"; then
    echo "error: README.txt contains an image tag" >&2
    return 1
  fi
}

self_test() {
  local tmp site
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # $tmp is fixed for this process
  trap "rm -rf '$tmp'" EXIT
  site="$tmp/photocraft-web-test"
  mkdir -p "$site/app" "$site/docs/brand" "$site/extra"
  cat >"$site/index.html" <<'EOF'
<!DOCTYPE html>
<html><head><title>PhotoCraft</title>
<link rel="icon" href="favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
</head>
<body>
<script src="./photocraft-web-boot.js"></script>
<a href="./app/parts.txt">parts</a>
</body></html>
EOF
  printf 'ico' >"$site/favicon.ico"
  printf 'png' >"$site/favicon-32.png"
  printf 'png' >"$site/apple-touch-icon.png"
  echo '<img alt="ArtCraft" src="docs/brand/artcraft-logo.svg">' >"$site/README.md"
  echo '<svg xmlns="http://www.w3.org/2000/svg"></svg>' >"$site/docs/brand/artcraft-logo.svg"
  echo 'mark' >"$site/extra/artcraft-mark.png"
  echo 'not-a-mark' >"$site/app/parts.txt"

  stage "$site"

  [ ! -f "$site/README.md" ]
  [ ! -e "$site/docs/brand" ]
  [ ! -f "$site/extra/artcraft-mark.png" ]
  [ -f "$site/app/parts.txt" ]
  [ -f "$site/favicon.ico" ]
  grep -q 'href="favicon.ico"' "$site/index.html"
  grep -q 'based on PhotoCraft by the ArtCraft team' "$site/README.txt"
  grep -q 'not affiliated with' "$site/README.txt"
  grep -q 'LICENSE-MIT' "$site/NOTICE"
  # The trademark terms travel with the site; the mark files do not.
  grep -q 'NOT open source' "$site/licenses/LICENSE-brand.txt"
  if grep -Eq '(src|href)="/[^/]' "$site/index.html"; then
    echo "error: self-test index.html was rewritten with a root-absolute URL" >&2
    exit 1
  fi

  echo '<script src="/photocraft/app.js"></script>' >"$site/index.html"
  if stage "$site" 2>"$tmp/err"; then
    echo "error: self-test expected root-absolute URLs to be rejected" >&2
    exit 1
  fi
  grep -q 'root-absolute' "$tmp/err"

  echo "pages-stage self-test ok" >&2
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

if [ -n "${1:-}" ]; then
  [ -d "$1" ] || { echo "error: $1 is not a directory" >&2; exit 1; }
  site=$(cd "$1" && pwd)
else
  work="$CARGO_TARGET_DIR/web-package"
  site=""
  for d in "$work"/photocraft-web-*; do
    [ -d "$d" ] || continue
    if [ -n "$site" ]; then
      echo "error: more than one site under $work" >&2
      exit 1
    fi
    site=$d
  done
  [ -n "$site" ] || { echo "error: no photocraft-web-* directory under $work; run packaging/web/package.sh" >&2; exit 1; }
  site=$(cd "$site" && pwd)
fi

stage "$site"
echo "$site"
