#!/usr/bin/env python3
"""Subset Noto Sans CJK for the PhotoCraft web package.

Wasm cannot read system fonts, and egui paints canvas text from font bytes, not CSS.
This downloads the pinned Noto Sans CJK subset OTFs (SIL OFL 1.1), keeps the
characters the UI catalogs and ordinary CJK typing need, and writes
``fonts/manifest.txt`` plus the faces. The binaries are not committed.

Source: https://github.com/notofonts/noto-cjk tag Sans2.004
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import time
import urllib.request
from pathlib import Path

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont

UA = "Photocraft-dev"
TAG = "Sans2.004"
RAW = f"https://raw.githubusercontent.com/notofonts/noto-cjk/{TAG}"
SOURCE = f"https://github.com/notofonts/noto-cjk/tree/{TAG}"

# (cache name, url, sha256)
SOURCES = [
    (
        "NotoSansSC-Regular.otf",
        f"{RAW}/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf",
        "faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9",
    ),
    (
        "NotoSansKR-Regular.otf",
        f"{RAW}/Sans/SubsetOTF/KR/NotoSansKR-Regular.otf",
        "69975a0ac8472717870aefeab0a4d52739308d90856b9955313b2ad5e0148d68",
    ),
    (
        "LICENSE",
        f"{RAW}/LICENSE",
        "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2",
    ),
]

# Punctuation, kana and bopomofo. The full ideograph block is the typing face only.
UI_EXTRA = [(0x3000, 0x303F), (0x3040, 0x30FF), (0x3100, 0x312F), (0x31C0, 0x31EF), (0xFF00, 0xFFEF)]
BMP = UI_EXTRA + [(0x4E00, 0x9FFF)]
HANGUL = [(0x1100, 0x11FF), (0x3130, 0x318F), (0xA960, 0xA97F), (0xAC00, 0xD7AF), (0xD7B0, 0xD7FF)]

# Family names the web shell requests before the full faces. Keep in sync with
# apps/photocraft-web/src/web.rs.
EAGER = ("Noto Sans SC UI", "Noto Sans KR UI")


def download(url: str, dest: Path, expect: str) -> None:
    if dest.is_file() and hashlib.sha256(dest.read_bytes()).hexdigest() == expect:
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_suffix(dest.suffix + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    last: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=180) as response, partial.open("wb") as out:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
            got = hashlib.sha256(partial.read_bytes()).hexdigest()
            if got != expect:
                raise RuntimeError(f"sha256 {got} != {expect}")
            partial.replace(dest)
            return
        except Exception as exc:  # noqa: BLE001 — retry network and hash failures
            last = exc
            partial.unlink(missing_ok=True)
            time.sleep(2 * (attempt + 1))
    raise SystemExit(f"error: could not download {url}: {last}")


def in_ranges(code: int, ranges: list[tuple[int, int]]) -> bool:
    return any(start <= code <= end for start, end in ranges)


def catalog_codes(directory: Path) -> set[int]:
    codes: set[int] = set()
    files = sorted(directory.glob("*.tsv"))
    if not files:
        raise SystemExit(f"error: no catalogs in {directory}")
    for path in files:
        text = path.read_text(encoding="utf-8")
        codes.update(ord(ch) for ch in text if ord(ch) > 127)
    return codes


def cmap_of(path: Path) -> set[int]:
    font = TTFont(path)
    cmap = font.getBestCmap() or {}
    return set(cmap)


def choose(cmap: set[int], ranges: list[tuple[int, int]], catalog: set[int], *, catalog_only: bool) -> set[int]:
    chosen: set[int] = set()
    for code in cmap:
        if catalog_only:
            if code in catalog and in_ranges(code, ranges):
                chosen.add(code)
        elif in_ranges(code, ranges) or code in catalog:
            chosen.add(code)
    if len(chosen) < 16:
        raise SystemExit(f"error: charset has only {len(chosen)} glyphs")
    return chosen


def family_name(font: TTFont) -> str:
    name = font["name"]
    typographic = name.getDebugName(16)
    legacy = name.getDebugName(1)
    return typographic or legacy or ""


def rename(font: TTFont, family: str) -> None:
    name = font["name"]
    platforms = {(rec.platformID, rec.platEncID, rec.langID) for rec in name.names if rec.nameID in (1, 16)}
    if not platforms:
        raise SystemExit(f"error: {family} has no name records to update")
    postscript = "".join(family.split()) + "-Regular"
    for platform, encoding, lang in platforms:
        name.setName(family, 1, platform, encoding, lang)
        name.setName(family, 4, platform, encoding, lang)
        name.setName(postscript, 6, platform, encoding, lang)
        name.setName(family, 16, platform, encoding, lang)
    if family_name(font) != family:
        raise SystemExit(f"error: renamed face reports {family_name(font)!r}, want {family!r}")


def subset(source: Path, dest: Path, unicodes: set[int], family: str | None) -> None:
    font = TTFont(source)
    options = Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    options.recommended_glyphs = True
    options.drop_tables = ["DSIG"]
    tool = Subsetter(options=options)
    tool.populate(unicodes=unicodes)
    tool.subset(font)
    if family is not None:
        rename(font, family)
    dest.parent.mkdir(parents=True, exist_ok=True)
    font.save(dest)
    reported = family_name(TTFont(dest))
    expect = family if family is not None else family_name(TTFont(source))
    if reported != expect:
        raise SystemExit(f"error: {dest.name} family is {reported!r}, want {expect!r}")


def require_glyphs(path: Path, chars: str) -> None:
    cmap = cmap_of(path)
    missing = [ch for ch in chars if ord(ch) not in cmap]
    if missing:
        raise SystemExit(f"error: {path.name} is missing {''.join(missing)}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the web CJK fallback fonts into a site directory.")
    parser.add_argument("--dest", type=Path, required=True, help="Site root (index.html's directory)")
    parser.add_argument("--cache", type=Path, required=True, help="Directory for the pinned source fonts")
    parser.add_argument("--catalogs", type=Path, required=True, help="Directory of UI catalogs (*.tsv)")
    args = parser.parse_args()

    for name, url, digest in SOURCES:
        download(url, args.cache / name, digest)

    catalog = catalog_codes(args.catalogs)
    sc_src = args.cache / "NotoSansSC-Regular.otf"
    kr_src = args.cache / "NotoSansKR-Regular.otf"
    sc_cmap = cmap_of(sc_src)
    kr_cmap = cmap_of(kr_src)
    # UI faces: catalog glyphs plus kana/punctuation (SC) or the catalog's hangul (KR).
    # Typing faces: the basic ideograph block, or every hangul syllable in the source.
    sc_ui = {code for code in choose(sc_cmap, UI_EXTRA, catalog, catalog_only=False) if code in catalog or in_ranges(code, UI_EXTRA)}
    faces = [
        ("NotoSansSC-UI.otf", sc_src, sc_ui, "Noto Sans SC UI", "简体文あ"),
        ("NotoSansSC-Regular.otf", sc_src, choose(sc_cmap, BMP, catalog, catalog_only=False), None, "简体文文件"),
        ("NotoSansKR-UI.otf", kr_src, choose(kr_cmap, HANGUL, catalog, catalog_only=True), "Noto Sans KR UI", "한글"),
        ("NotoSansKR-Regular.otf", kr_src, {code for code in kr_cmap if in_ranges(code, HANGUL)}, None, "한글"),
    ]
    out_dir = args.dest / "fonts" / "noto"
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[tuple[str, str, str, str]] = []
    limits = {
        "NotoSansSC-UI.otf": 2_000_000,
        "NotoSansKR-UI.otf": 500_000,
        "NotoSansSC-Regular.otf": 8_000_000,
        "NotoSansKR-Regular.otf": 3_000_000,
    }
    scripts = {
        # `Ui` is not a document script: the web shell fetches these for egui only.
        "NotoSansSC-UI.otf": "Ui",
        "NotoSansKR-UI.otf": "Ui",
        "NotoSansSC-Regular.otf": "Hans,Hant,Jpan",
        "NotoSansKR-Regular.otf": "Kore",
    }
    families = {
        "NotoSansSC-UI.otf": "Noto Sans SC UI",
        "NotoSansKR-UI.otf": "Noto Sans KR UI",
        "NotoSansSC-Regular.otf": "Noto Sans SC",
        "NotoSansKR-Regular.otf": "Noto Sans KR",
    }
    for filename, source, unicodes, rename_to, sample in faces:
        dest = out_dir / filename
        subset(source, dest, unicodes, rename_to)
        require_glyphs(dest, sample)
        size = dest.stat().st_size
        if size > limits[filename] or size < 1000:
            raise SystemExit(f"error: {filename} is {size} bytes, outside 1000..{limits[filename]}")
        rel = f"fonts/noto/{filename}"
        written.append((families[filename], rel, scripts[filename], sha256(dest)))
        print(f"{rel}: {size} bytes, {len(unicodes)} source glyphs, family {families[filename]}")

    license_dest = out_dir / "OFL.txt"
    license_dest.write_bytes((args.cache / "LICENSE").read_bytes())
    if sha256(license_dest) != SOURCES[2][2]:
        raise SystemExit("error: OFL.txt does not match the pinned Noto CJK license")

    lines = [
        "# Generated by packaging/web/cjk_font.py. Do not edit.",
        "# family | style | file | scripts | licence | licence file | sha256 | source",
    ]
    for family, rel, script, digest in written:
        lines.append(f"{family} | Regular | {rel} | {script} | OFL-1.1 | fonts/noto/OFL.txt | {digest} | {SOURCE}")
    manifest = args.dest / "fonts" / "manifest.txt"
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    eager = {family for family, _, _, _ in written}
    if not set(EAGER).issubset(eager):
        raise SystemExit(f"error: manifest is missing {set(EAGER) - eager}")
    print(f"wrote {manifest}")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(1)
