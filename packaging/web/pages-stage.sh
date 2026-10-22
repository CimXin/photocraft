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
# shellcheck source=build-badge.sh
. "$HERE/build-badge.sh"

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

  # Version + commit, visible before the wasm loads and after #photocraft_loading is removed.
  stamp_build_badge "$site/index.html" || return 1
  assert_build_badge "$site/index.html" || return 1
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
<div id="photocraft_loading"><p>正在加载 PhotoCraft</p></div>
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
  assert_build_badge "$site/index.html"
  # Stamping again replaces the badge; it must not stack a second copy.
  stage "$site"
  assert_build_badge "$site/index.html"
  badge_outside_loading "$site/index.html"
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

  badge_rejects_unsafe_tokens "$tmp"
  badge_on_boot_page "$tmp/boot.html"

  echo "pages-stage self-test ok" >&2
}

# The app deletes #photocraft_loading. The badge has to be a sibling, or the
# running editor would have no version on screen.
badge_outside_loading() {
  local html="$1"
  if ! awk '
    /id="photocraft_loading"/ { inload = 1 }
    inload && /id="photocraft_build"/ { found = 1 }
    inload && /<\/div>/ { inload = 0 }
    END { exit found ? 1 : 0 }
  ' "$html"; then
    echo "error: self-test: build badge is inside #photocraft_loading" >&2
    exit 1
  fi
  grep -q 'id="photocraft_build"' "$html"
}

# A commit or date with markup must be dropped, not written into the page.
badge_rejects_unsafe_tokens() {
  local tmp="$1" saved_sha saved_date html
  saved_sha="${PHOTOCRAFT_BUILD_SHA:-}"
  saved_date="${PHOTOCRAFT_BUILD_DATE:-}"
  html="$tmp/badge.html"
  printf '%s\n' '<!DOCTYPE html><html><body><div id="photocraft_loading"><p>正在加载</p></div></body></html>' >"$html"

  PHOTOCRAFT_BUILD_SHA=9ca4b8a1b2c3d4e5f678901234567890abcdef12
  PHOTOCRAFT_BUILD_DATE=2026-10-22
  stamp_build_badge "$html"
  grep -F "data-version=\"${VERSION}\"" "$html" >/dev/null
  grep -F 'data-sha="9ca4b8a"' "$html" >/dev/null
  grep -F 'data-date="2026-10-22"' "$html" >/dev/null
  grep -F "v${VERSION} · 9ca4b8a" "$html" >/dev/null
  grep -F 'pointer-events:none' "$html" >/dev/null
  badge_outside_loading "$html"
  stamp_build_badge "$html"
  [ "$(grep -c 'id="photocraft_build"' "$html")" -eq 1 ]

  PHOTOCRAFT_BUILD_SHA='9ca4b8a"><script>alert(1)</script>'
  PHOTOCRAFT_BUILD_DATE='2026-10-22<img>'
  stamp_build_badge "$html"
  if grep -F 'script' "$html" || grep -F '<img' "$html"; then
    echo "error: self-test: badge wrote an unsafe commit or date" >&2
    exit 1
  fi
  if grep -F 'data-sha=' "$html" || grep -F 'data-date=' "$html"; then
    echo "error: self-test: unsafe commit or date was kept on the badge" >&2
    exit 1
  fi
  grep -F ">v${VERSION}<" "$html" >/dev/null

  PHOTOCRAFT_BUILD_SHA="$saved_sha"
  PHOTOCRAFT_BUILD_DATE="$saved_date"
}

# The page Trunk actually ships, not only the one-line fixture: the badge goes
# after the loading node, and the source file itself stays unstamped.
badge_on_boot_page() {
  local html="$1" src
  src="$ROOT/apps/photocraft-web-boot/index.html"
  [ -f "$src" ] || { echo "error: $src missing" >&2; exit 1; }
  if grep -q 'id="photocraft_build"' "$src" "$ROOT/apps/photocraft-web/index.html"; then
    echo "error: source index.html must not carry a build badge (it would go stale)" >&2
    exit 1
  fi
  cp "$src" "$html"
  stamp_build_badge "$html"
  assert_build_badge "$html"
  badge_outside_loading "$html"
  grep -F 'id="photocraft_stalled"' "$html" >/dev/null
  grep -F 'href="favicon.ico"' "$html" >/dev/null
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
