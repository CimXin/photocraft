# Hosting PhotoCraft for the web

`photocraft-web-<version>.zip` (from the GitHub release, or `packaging/web/package.sh`) holds a
static site in `photocraft-web-<version>/`:

| File | What it is |
|---|---|
| `index.html` | The page. It loads everything through relative URLs. A bottom-right badge shows the version and short commit. |
| `photocraft-web-boot-<hash>.js`, `photocraft-web-boot-<hash>_bg.wasm` | A small module (about 120 KB) that starts the app from its parts, with its wasm-bindgen glue |
| `app/photocraft-web-<hash>.part-aa`, `-ab`, … | The app's WebAssembly, gzipped and cut into parts of at most 20 MiB (see [Sizes](#sizes)) |
| `app/parts.txt` | The parts, in order |
| `app/photocraft-web.js` | The app's wasm-bindgen glue (generated, ES module) |
| `_headers`, `.htaccess` | Sample header rules for Netlify/Cloudflare Pages and Apache |
| `fonts/` (optional) | Fonts loaded on demand, listed in `fonts/manifest.txt` (see [Fonts](#fonts)) |

There is no server-side code. Upload the folder's contents anywhere that serves static files.

## Docker

> The Docker recipe (`Dockerfile`, `.dockerignore`, `packaging/web/nginx.conf`) is
> **community-maintained**: it is not built in CI or used for releases, so it can lag behind the
> official web build above. Fixes are welcome.

From the repository root (Docker is the only build prerequisite):

```sh
docker build --load -t photocraft-web:local .
docker run -d --name photocraft-web --restart unless-stopped \
  -p 8080:8080 photocraft-web:local
```

Open **http://localhost:8080/**. The multi-stage `Dockerfile` builds the existing Rust/Wasm
app with Trunk, including HEIF support, then copies only the static site into NGINX. The
runtime runs as the `nginx` user on port **8080**, with a `/healthz` endpoint and Docker
health check. It serves precompressed gzip assets, the Wasm MIME type, immutable hashed
assets, and an HTML page that revalidates after deployments. No Rust installation, Node.js,
database, GPU passthrough, or document volume is needed on the host.

The first build downloads Rust dependencies and Trunk's Wasm tools and can take several
minutes. Subsequent builds reuse Cargo caches. The builder supports Linux amd64 and arm64;
the default Rust version is the stable release CI used when the `Dockerfile` was last updated
(CI and releases always use the latest stable), and Trunk is pinned to the release workflow's
`TRUNK_VERSION`. `RUST_VERSION`, `TRUNK_VERSION`, and `NGINX_VERSION` can be overridden with
`--build-arg`. To stamp the About dialog with the commit and date instead of "dev build", pass
`--build-arg PHOTOCRAFT_BUILD_SHA=$(git rev-parse HEAD) --build-arg PHOTOCRAFT_BUILD_DATE=$(date -u +%F)`.
The web build does not embed the optional `craft-fonts` checkout.

The Docker build uses thin LTO and one Cargo build job to reduce peak memory, while keeping
the web profile's size optimizations and `wasm-opt -Oz`. Its Wasm size may differ from the
release zip figures below; NGINX has no 25 MiB file limit. To use the release zip's fat LTO on
a builder with more memory, pass `--build-arg CARGO_PROFILE_WASM_RELEASE_LTO=fat`.
`--build-arg CARGO_BUILD_JOBS=4` enables more concurrent compilation on larger builders. A compiler killed with
`SIGKILL`/`cannot allocate memory` means the Docker/Podman VM needs more memory or swap.

For a public deployment, put an HTTPS reverse proxy or your hosting platform's TLS endpoint
in front of container port 8080. With a reverse proxy on the same host, bind only loopback
(`-p 127.0.0.1:8080:8080`); with a proxy container, connect both through a Docker network.
HTTPS enables WebGPU and browser clipboard APIs. If hosting under `/photocraft/`, redirect
`/photocraft` to `/photocraft/` and strip that prefix when proxying to the container. Relative
asset URLs then work without rebuilding. For example, in an existing HTTPS NGINX server:

```nginx
location = /photocraft { return 301 /photocraft/; }
location /photocraft/ {
    proxy_pass http://127.0.0.1:8080/;
}
```

The editor and image processing run on the visitor's device. Open uses the browser file
picker; Save and Export download files. Preferences use browser localStorage. There is no
server-side document storage, desktop TCP control server, or web autosave/crash recovery;
save/download work before closing or reloading the page. A browser with WebGPU or WebGL2 is
required; `?webgl` forces the fallback when troubleshooting. In a browser that can't
inflate a stream itself (no `DecompressionStream`: before Safari 16.4 and Firefox 113), the
release zip's site inflates the app's parts in its own code, a little slower.

To verify the browser deployment, open the page, open an image and save/export it.

## Sizes

Measured on 2026-10-13 (0.8.2, `packaging/web/package.sh`):

| File | Size |
|---|---|
| `app/photocraft-web-<hash>.part-aa` (the only part today) | 11,401,527 bytes (10.9 MiB) |
| `app/photocraft-web.js` | about 170 KB (26 KB with gzip) |
| `photocraft-web-boot-<hash>_bg.wasm` and `.js` | about 120 KB together |

The app's WebAssembly is 25,019,043 bytes (23.9 MiB) before gzip.

Per-file upload limits: Cloudflare Pages and Workers static assets reject any file over
**25 MiB** (26,214,400 bytes), and the app's WebAssembly is at that size. (Releases up to 0.2.0
shipped a 25.8 MiB wasm, which Cloudflare rejected; issue #198.) So the site doesn't hold it as
one file: packaging gzips it and cuts the result into parts of at most 20 MiB, and the page puts
them back together while it downloads them. `packaging/web/package.sh` fails if any file in the
site is over 24 MiB, so a release can't ship a file a common host refuses, and the app can grow
without reaching that limit (issue #5302). A build straight from Trunk (`trunk build --release`
in `apps/photocraft-web`, or the Docker image above) still has the app in one `.wasm`, for hosts
without such a cap.

The app is built with the `wasm-release` Cargo profile (fat LTO, size-optimized code with the
pixel and file-decoding crates kept at speed) plus `wasm-opt -Oz`, and stores the bundled fonts
(PhotoCraft's and egui's) and the translation catalogs compressed, unpacked on first use.

## Any path works

All URLs in `index.html` are relative (`public_url = "./"` in `apps/photocraft-web/Trunk.toml`),
so the site works at a domain root (`https://example.com/`), under a prefix
(`https://example.com/tools/photocraft/`) and from a CDN bucket. The asset names carry a content
hash, so they can be cached forever. `index.html`, `app/photocraft-web.js` and `app/parts.txt` keep
their names and need revalidation.

## Required server settings

- **MIME type:** serve `.wasm` as `application/wasm`. Browsers refuse to stream-compile it under
  any other type, and the app then loads slowly or not at all. Serve `.js` as `text/javascript`.
  Most hosts already do both. For nginx, check that `mime.types` has `application/wasm wasm;`.
- **The parts as they are:** serve `app/*.part-*` byte for byte, with no `Content-Encoding` (they
  are gzip already, and the page inflates them). Their extension is one servers don't
  know, so the usual result, `application/octet-stream` and no compression, is right.
- **Missing files are 404s:** a host that answers every unknown path with `index.html` (a
  single-page-app fallback) hides a failed upload. PhotoCraft notices and says the download
  failed, but a 404 is clearer in the server's logs.
- **Compression:** turn on gzip or Brotli for `.wasm`, `.js` and `.html`. It matters little for
  the download, since the parts are compressed already; it shrinks the two `.js` files and the
  small boot module. You can also precompress and let the server send `Content-Encoding: br`.
- **Caching:** `Cache-Control: public, max-age=31536000, immutable` on the files whose names
  carry a hash (the parts and `photocraft-web-boot-<hash>.*`), and `no-cache` on `index.html`,
  `app/photocraft-web.js` and `app/parts.txt`. The sample `_headers` and `.htaccess` do this.
- **HTTPS:** WebGPU (and the clipboard) only work in a secure context, which means `https://`
  or `http://localhost`. Over plain HTTP elsewhere, the app falls back to WebGL2.
- **No special isolation headers:** PhotoCraft doesn't use `SharedArrayBuffer`, so it doesn't
  need `Cross-Origin-Opener-Policy` or `Cross-Origin-Embedder-Policy`. If your site already sends
  COEP `require-corp`, also send `Cross-Origin-Resource-Policy: same-origin` (or `cross-origin`
  when the files live on a CDN) on the app's files.

nginx example:

```nginx
location /photocraft/ {
    types { application/wasm wasm; text/javascript js; text/html html; }
    gzip on;
    gzip_types application/wasm text/javascript text/html;
    # The first matching line wins, so the files that keep their names come first.
    location ~* (index\.html|app/photocraft-web\.js|app/parts\.txt)$ { add_header Cache-Control "no-cache"; }
    location ~* (\.(wasm|js)|\.part-[a-z]+)$ { add_header Cache-Control "public, max-age=31536000, immutable"; }
}
```

Local test: `python3 -m http.server 8765` inside the folder, then open http://localhost:8765/.

## Fonts

The app has two fonts of its own, Inter and JetBrains Mono. A browser's CSS fonts do not reach
egui's canvas, and embedding a full CJK face would push the wasm over the size gate. A host can
serve more fonts next to the
app. They show in the font menus straight away, and a family's files are downloaded the first time
it is picked or a document's text needs it, so starting the app costs one small text file.

1. Put the font files (`.ttf`, `.otf`, `.ttc`) anywhere under `fonts/` next to `index.html`.
2. List them in `fonts/manifest.txt`, one file per line, in the format of
   [craft-fonts](https://github.com/storytold/craft-fonts)' own `fonts/manifest.txt`:

   ```text
   # family | style | file (relative to the site root) | scripts | licence | licence file | sha256 | source
   Open Sans | Regular | fonts/open-sans/OpenSans[wdth,wght].ttf
   Open Sans | Italic | fonts/open-sans/OpenSans-Italic[wdth,wght].ttf
   Lobster | Regular | fonts/lobster/Lobster-Regular.ttf | Latn,Cyrl | OFL-1.1 | fonts/lobster/OFL.txt
   ```

   The app reads the first three fields; the others are optional here. `family` must be the font's
   own family name (the typographic family in its `name` table, else the family), which is what the
   font menu shows once the file is in. The path is relative to the site root and can't leave it
   (no `..`, no `/` at the start, no other host). A variable font is one line: the style menu offers
   the weights of its `wght` axis.
3. Put each font's licence next to it; the SIL Open Font License, for one, requires that.

A craft-fonts checkout is already laid out this way, and so is any folder with a
`fonts/manifest.txt` and the files it lists: `PHOTOCRAFT_WEB_FONTS_DIR=<that folder>
packaging/web/package.sh` copies the manifest, the fonts and their licences into the zip, keeping
their paths. Without `fonts/manifest.txt` (a 404) nothing changes.

Serving: let `fonts/manifest.txt` revalidate (`Cache-Control: no-cache`) so edits show up; cache
the font files for long only if their names change with their contents. Serve `.ttf` as `font/ttf`
and `.otf` as `font/otf`, and compress them (Brotli roughly halves a TrueType file). The app
fetches them with `fetch()`, so a Content Security Policy needs them allowed by `connect-src`.

## Embedding in a page (iframe)

```html
<iframe
  src="https://example.com/photocraft/"
  title="PhotoCraft image editor"
  style="width: 100%; height: 720px; border: 0;"
  allow="fullscreen; clipboard-read; clipboard-write"
  allowfullscreen>
</iframe>
```

- The app fills the iframe and follows its size, so size the iframe and not the app.
- Keyboard shortcuts go to the iframe after the user clicks into it, as with any embedded app.
- **Cross-origin embeds** work. Preferences are kept in the iframe's `localStorage`. Browsers
  that partition or block third-party storage may forget them between visits, and the app
  then starts with defaults.
- **Sandboxed iframes** need at least
  `sandbox="allow-scripts allow-same-origin allow-downloads allow-popups"`. Without
  `allow-same-origin` there's no storage. Without `allow-downloads`, Save and Export (browser
  downloads) are blocked.
- Don't send `X-Frame-Options: DENY` or a `frame-ancestors` CSP that excludes the embedding page.

## Renderer selection and fallback flags

PhotoCraft renders with wgpu. It uses **WebGPU** when the browser has it and falls back to
**WebGL2** on its own. URL query flags override this, and they work on the iframe `src` too:

| Flag | Effect |
|---|---|
| *(none)* | WebGPU if available, otherwise WebGL2 |
| `?webgl` | Force the WebGL2 backend (useful when a WebGPU driver misbehaves) |
| `?cpu` | Force the CPU canvas path (slowest, most compatible) |

For example: `<iframe src="https://example.com/photocraft/?webgl" ...>`.

A browser with neither WebGPU nor WebGL2 gets a message in place of the app.

## GitHub Pages

This fork publishes the same static site with GitHub Actions, for ongoing use at
**https://cimxin.github.io/photocraft/** (a project site: the repository name is the path).

### Enable it once

GitHub does not turn Pages on by itself. `actions/configure-pages` cannot either: enabling
Pages needs a token this workflow does not have. Before the first deploy:

1. Merge the workflow on `main` (`.github/workflows/pages.yml`).
2. Open **Settings → Pages → Build and deployment** and set **Source** to **GitHub Actions**.
3. If the merge already started the workflow, its **Setup Pages** step stops immediately
   while Pages is still off (before the WebAssembly build) and tells you to enable it.
   Open **Actions → GitHub Pages** and re-run that workflow. Or start it with
   **workflow_dispatch**.

The workflow runs on every push to `main`, and when started by hand. It builds with
`packaging/web/package.sh`, then `packaging/web/pages-stage.sh`, and deploys with
`actions/upload-pages-artifact` and `actions/deploy-pages`. Publish the staged directory
(the folder inside the zip, not the zip). Do not put that folder inside another
`photocraft/` directory: project Pages already serves the artifact at `/photocraft/`.

Relative asset URLs (`public_url = "./"`) are what makes that path work. Open the site with
the trailing slash: `https://cimxin.github.io/photocraft/`.

The published page carries a small bottom-right badge, `v<version> · <commit>`, so a visitor
can see which build is running without opening About. `packaging/web/build-badge.sh` writes it
when the site is packaged. The version is `[workspace.package] version`. The commit is
`PHOTOCRAFT_BUILD_SHA` (the Pages workflow sets that from `GITHUB_SHA`; otherwise `git
rev-parse HEAD`). The badge is plain HTML: it is on screen while the wasm is still
downloading, it is not inside the loading message the app removes, and it ignores pointer
events so it does not block the canvas. The full commit and the UTC build date are on the
element's `title`. An unsafe commit string is omitted rather than written into the page.

### HTTPS and WebGPU

Pages serves the site over HTTPS. WebGPU and the clipboard only work in a secure context
(`https://`, or `http://localhost`). Use the `https://cimxin.github.io` URL above.

### Notices, and marks that are not included

`pages-stage.sh` keeps `LICENSE-MIT`, `LICENSE-APACHE`, `NOTICE`, `ATTRIBUTION.md` and
`HOSTING.md` (this file) next to `index.html`, and copies the font, icon, word-list and
translation license texts into `licenses/`, including `docs/brand/LICENSE-brand.txt` (the
terms only). It removes the repository `README.md` from the site, because that file embeds
the ArtCraft wordmarks, and it deletes any `artcraft-logo*` / `artcraft-mark*` file. The
landing page is the app (`index.html`), with a plain-text `README.txt`: this deployment is
based on PhotoCraft by the ArtCraft team, and is not an ArtCraft product and not affiliated
with Adobe. The PhotoCraft app icon is part of the app (MIT OR Apache-2.0); it is not an
ArtCraft logo.

### Memory and time on GitHub-hosted runners

The `wasm-release` profile uses fat LTO. `.github/workflows/ci.yml` builds that on
`ubuntu-latest` (the `web` job). The link or `wasm-opt` can still be killed with `SIGKILL`
/ `cannot allocate memory` on a smaller machine — that is what the Dockerfile's builder
flags are for. The Pages workflow keeps thin LTO for the same reason. It sets
`CARGO_BUILD_JOBS=2`, not 1 and not 4: a standard GitHub-hosted runner has 4 vCPU and
16 GiB, and two thin-LTO `rustc` processes leave room for the multi-gigabyte codegen of
`engine` / `ui-egui` / `gpu` and for `wasm-opt`. Four concurrent jobs is what the
Dockerfile offers a larger builder, and what already fills a 12 GiB FreeBSD VM.

`package.sh` still fails the build if any file exceeds 24 MiB. The wasm can be slightly
larger than a release zip built with fat LTO. With the cargo and trunk caches, a main
push that rebuilds the site has been about 10–21 minutes (measured October 2026), not
the one-to-two-hour serial cold builds from before those caches. Most of a warm run is
one crate (`photocraft-web`) plus `wasm-opt`, which stay single-job; `CARGO_BUILD_JOBS=2`
shortens the independent crates around them, and a cache miss by much more. The job's
time limit is 360 minutes.

### CJK text on the web

egui draws the editor on a canvas from font files. The loading line above the canvas is
ordinary HTML, so `system-ui` and a CJK stack (`PingFang SC`, `Microsoft YaHei`, …) can
draw it. That CSS does not reach menu labels, panels or type layers.

Wasm also has no portable way to read the operating system's fonts. There is no filesystem
font scan, fontique's system backend is not linked, and the Local Font Access API
(`queryLocalFonts`) asks for a permission, needs a user gesture, and is missing in Firefox
and Safari. A Pages visitor would still see empty boxes if the app waited on that API.

`package.sh` therefore downloads the pinned Noto Sans CJK subset OTFs (SIL OFL 1.1, tag
`Sans2.004`) and subsets them into `fonts/` (see `cjk_font.py`). Two small faces cover the
UI catalogs, kana, punctuation and the hangul used in the menus, and load first. Two larger
faces cover the basic CJK ideograph block and hangul syllables for typing. Nothing is
committed to the repository. Han uses the Simplified Chinese forms in that face.

Set `PHOTOCRAFT_WEB_FONTS_DIR` to replace this step with another manifest, or
`PHOTOCRAFT_WEB_SKIP_CJK_FONT=1` to ship no CJK faces (canvas CJK is then missing glyphs).
The Pages workflow does neither: the subset is part of the site.

### Dry run without a wasm build

Staging can be checked on its own. It builds a fake site, checks the license files, checks
that a root-absolute URL is rejected, checks that ArtCraft mark files are removed, and checks
that the version badge is stamped once, outside the loading message:

```sh
packaging/web/pages-stage.sh --self-test
```

After a real package, stage that output and open it locally (any path prefix works the same
way Pages will):

```sh
packaging/web/package.sh
site="$(packaging/web/pages-stage.sh)"
python3 -m http.server 8765 -d "$site"
```

`package.sh` needs [trunk](https://trunkrs.dev) (`cargo install trunk --locked`) and the
`wasm32-unknown-unknown` target. `--self-test` needs neither.
