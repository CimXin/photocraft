#!/usr/bin/env bash
# Download and subset the CJK faces the web package serves. The font files are not
# committed. Details: packaging/web/cjk_font.py and packaging/web/README.md.
#
# Usage: packaging/web/cjk-font.sh <site-dir>
set -euo pipefail
# shellcheck source=../env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
HERE="$(dirname "${BASH_SOURCE[0]}")"
SITE="${1:?usage: packaging/web/cjk-font.sh <site-dir>}"

if ! python3 -c "import fontTools" >/dev/null 2>&1; then
  if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "error: fontTools is not installed and python3 -m pip is unavailable" >&2
    exit 1
  fi
  python3 -m pip install --user --disable-pip-version-check fonttools \
    || python3 -m pip install --user --disable-pip-version-check --break-system-packages fonttools
fi

python3 "$HERE/cjk_font.py" \
  --dest "$SITE" \
  --cache "$CARGO_TARGET_DIR/cjk-font-cache" \
  --catalogs "$ROOT/crates/ui-egui/src/i18n"
