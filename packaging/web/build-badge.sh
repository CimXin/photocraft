# shellcheck shell=bash
# Corner build badge for the packaged web page. Source after packaging/env.sh:
#   . "$(dirname "$0")/build-badge.sh"    # from packaging/web/*.sh
#
# package.sh and pages-stage.sh stamp index.html at build time. The text is the
# workspace version plus a 7-character commit (PHOTOCRAFT_BUILD_SHA, which the
# Pages workflow sets from GITHUB_SHA). Nothing here is compiled in, so the badge
# is on screen while the wasm is still downloading, and it stays after the app
# removes #photocraft_loading. Trunk's source pages are left alone: a dev build
# has no stale commit baked into the HTML.
#
# The badge is one line, click-through (pointer-events:none), and sits just above
# the Pro status bar so it does not cover the zoom field.

# Fill BUILD_BADGE_LABEL / _SHA / _SHA_FULL / _DATE from VERSION and the build
# environment. A commit or date that is not a plain token is dropped, never
# written into the HTML.
build_badge_fields() {
  local sha date
  BUILD_BADGE_LABEL=""
  BUILD_BADGE_SHA=""
  BUILD_BADGE_SHA_FULL=""
  BUILD_BADGE_DATE=""
  if [ -z "${VERSION:-}" ]; then
    echo "error: VERSION is not set (source packaging/env.sh first)" >&2
    return 1
  fi
  case "$VERSION" in
    *[!0-9A-Za-z._+-]* | "")
      echo "error: refusing to stamp version '$VERSION'" >&2
      return 1
      ;;
  esac
  sha="${PHOTOCRAFT_BUILD_SHA:-}"
  sha="${sha#"${sha%%[![:space:]]*}"}"
  sha="${sha%"${sha##*[![:space:]]}"}"
  case "$sha" in
    *[!0-9a-fA-F]* | "") sha="" ;;
  esac
  if [ -n "$sha" ]; then
    sha="$(printf '%s' "$sha" | tr 'A-F' 'a-f')"
    if [ "${#sha}" -lt 7 ] || [ "${#sha}" -gt 64 ]; then
      sha=""
    fi
  fi
  if [ -z "$sha" ] && [ -n "${PHOTOCRAFT_BUILD_SHA:-}" ]; then
    warn "PHOTOCRAFT_BUILD_SHA is not a 7-64 character git commit; the page badge omits it"
  fi
  date="${PHOTOCRAFT_BUILD_DATE:-}"
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    "") ;;
    *)
      warn "PHOTOCRAFT_BUILD_DATE is not YYYY-MM-DD; the page badge omits it"
      date=""
      ;;
  esac
  if [ -n "$sha" ]; then
    BUILD_BADGE_SHA_FULL="$sha"
    BUILD_BADGE_SHA="$(printf '%s' "$sha" | cut -c1-7)"
    BUILD_BADGE_LABEL="v${VERSION} · ${BUILD_BADGE_SHA}"
  else
    BUILD_BADGE_LABEL="v${VERSION}"
  fi
  BUILD_BADGE_DATE="$date"
}

# Rewrite "$1" (an index.html) so it contains exactly one #photocraft_build badge.
stamp_build_badge() {
  local html="$1" title style badge tmp
  if [ -z "$html" ] || [ ! -f "$html" ]; then
    echo "error: index.html missing: ${html:-}" >&2
    return 1
  fi
  build_badge_fields || return 1
  title="PhotoCraft ${VERSION}"
  if [ -n "$BUILD_BADGE_SHA_FULL" ]; then
    title="${title} (${BUILD_BADGE_SHA_FULL})"
  fi
  if [ -n "$BUILD_BADGE_DATE" ]; then
    title="${title} ${BUILD_BADGE_DATE}"
  fi
  # system-ui matches the loading line. The label is Latin, so no CJK face is required.
  # bottom: 30px clears the 24px Pro status bar. pointer-events:none lets clicks through.
  style='position:fixed;right:10px;bottom:30px;z-index:20;margin:0;padding:2px 7px;border-radius:3px;background:rgba(0,0,0,0.45);color:rgba(255,255,255,0.78);font:11px/1.35 system-ui,sans-serif;white-space:nowrap;pointer-events:none;user-select:none;-webkit-user-select:none;'
  badge="<div id=\"photocraft_build\" translate=\"no\" data-version=\"${VERSION}\""
  if [ -n "$BUILD_BADGE_SHA" ]; then
    badge="${badge} data-sha=\"${BUILD_BADGE_SHA}\""
  fi
  if [ -n "$BUILD_BADGE_DATE" ]; then
    badge="${badge} data-date=\"${BUILD_BADGE_DATE}\""
  fi
  badge="${badge} title=\"${title}\" style=\"${style}\">${BUILD_BADGE_LABEL}</div>"
  tmp="$(mktemp)"
  # A previous stamp is a single line. Drop it, then insert the new one before </body>
  # so it is outside #photocraft_loading (the app removes that node when it starts).
  if ! awk -v badge="$badge" '
    {
      line = $0
      sub(/^[ \t\r]+/, "", line)
    }
    index(line, "<div id=\"photocraft_build\"") == 1 { next }
    !inserted && tolower($0) ~ /<\/body>/ {
      print "  " badge
      inserted = 1
    }
    { print }
    END {
      if (!inserted) print badge
    }
  ' "$html" >"$tmp"; then
    rm -f "$tmp"
    echo "error: could not stamp the build badge into $html" >&2
    return 1
  fi
  mv "$tmp" "$html"
  echo "build badge: ${BUILD_BADGE_LABEL}" >&2
}

# Fail when the page lost the badge, nested it inside the loading node, or dropped
# the version / commit this process is supposed to publish.
assert_build_badge() {
  local html="$1" count
  [ -f "$html" ] || { echo "error: $html missing" >&2; return 1; }
  build_badge_fields || return 1
  count="$(grep -c 'id="photocraft_build"' "$html" || true)"
  [ "$count" -eq 1 ] || { echo "error: expected one build badge in $html, found ${count:-0}" >&2; return 1; }
  if ! grep -F "data-version=\"${VERSION}\"" "$html" >/dev/null; then
    echo "error: build badge is missing version ${VERSION}" >&2
    return 1
  fi
  if ! grep -F ">${BUILD_BADGE_LABEL}<" "$html" >/dev/null; then
    echo "error: build badge text is not ${BUILD_BADGE_LABEL}" >&2
    return 1
  fi
  if ! grep -F 'pointer-events:none' "$html" >/dev/null; then
    echo "error: build badge does not ignore pointer events" >&2
    return 1
  fi
  if [ -n "$BUILD_BADGE_SHA" ] && ! grep -F "data-sha=\"${BUILD_BADGE_SHA}\"" "$html" >/dev/null; then
    echo "error: build badge is missing commit ${BUILD_BADGE_SHA}" >&2
    return 1
  fi
  if [ -n "$BUILD_BADGE_DATE" ] && ! grep -F "data-date=\"${BUILD_BADGE_DATE}\"" "$html" >/dev/null; then
    echo "error: build badge is missing date ${BUILD_BADGE_DATE}" >&2
    return 1
  fi
  if grep -q 'id="photocraft_loading"' "$html"; then
    if ! awk '
      /id="photocraft_loading"/ { inload = 1 }
      inload && /id="photocraft_build"/ { found = 1 }
      inload && /<\/div>/ { inload = 0 }
      END { exit found ? 1 : 0 }
    ' "$html"; then
      echo "error: build badge is inside #photocraft_loading and would vanish when the app starts" >&2
      return 1
    fi
  fi
}
