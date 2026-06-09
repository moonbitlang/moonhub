# hackwaly/moonhub

## Browser Assets

The rich code views are built from the JavaScript project under `js/` and
emitted into the repository `assets/` directory:

```sh
cd js
npm install
npm run build
```

Run the build again after changing files under `js/src/`. The MoonBit server
reads the configured assets directory's `.vite/manifest.json` to load the hashed
`custom-elements` bundle. The manifest is required; public files served from
`/assets/` are treated as immutable build artifacts, and `.vite/manifest.json`
is not served publicly.

The top-level owner name `assets` is reserved for browser assets, so repositories
under `assets/*.git` are intentionally ignored by the repository browser.

## Manual Testing

Use the tracked test fixture under `testdata/repos`:

```sh
moon run . -- testdata/repos --assets ./assets --host 127.0.0.1 --port 8080
```

Then open these pages in a browser:

- <http://127.0.0.1:8080/>
- <http://127.0.0.1:8080/alice/demo>
- <http://127.0.0.1:8080/alice/demo/tree/master>
- <http://127.0.0.1:8080/alice/demo/blob/master/README.md>
- <http://127.0.0.1:8080/alice/demo/blob/master/src/main.mbt>
- <http://127.0.0.1:8080/alice/demo/commits>

To inspect a commit page, get the fixture commit hash first:

```sh
git --git-dir=testdata/repos/alice/demo.git rev-parse master
```

Then open:

```text
http://127.0.0.1:8080/alice/demo/commit/<commit-hash>
```

Press `Ctrl-C` in the terminal running `moon run` to stop the server.
