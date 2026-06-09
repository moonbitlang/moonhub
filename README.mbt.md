# hackwaly/moonhub

## Manual Testing

Use the tracked test fixture under `testdata/repos`:

```sh
moon run . -- testdata/repos --host 127.0.0.1 --port 8080
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
