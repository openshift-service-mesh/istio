# BookInfo, rewritten in Go

This is a rewrite of the four BookInfo application services in Go. It is a
drop-in replacement for [`samples/bookinfo/src`](../bookinfo/src): the HTTP
APIs, the environment variables and the image names remain compatible, so the
manifests, tasks and tests that target the original sample work unchanged
against these images. The rendered HTML may differ from the original app.

The point of the rewrite is the dependency footprint. The original services
pull in Flask, gunicorn, gevent, Ruby's WEBrick and bundler, a `node_modules`
tree and the Open Liberty application server, and the images that carry them
inherit a steady stream of CVEs from a language runtime and a Debian
userland.

| | original | this rewrite |
| --- | --- | --- |
| third-party packages | hundreds, across four ecosystems | none |
| base image | `python`, `ruby`, `node`, `websphere-liberty` | `scratch` |
| image contents | a language runtime, a package tree, a Debian userland | one static binary |
| image size | a runtime plus its userland | 6 MB – 10 MB |

## Zero dependencies

`go.mod` has no `require` block and there is no `go.sum`. Every import in
`cmd/` and `internal/` resolves to the Go standard library, so the only thing
that can carry a CVE into these images is the Go toolchain used to build them.
Please keep it that way; the sample exists to be copied.

The product page templates and static assets are compiled into the binary with
`go:embed`, which is what makes a `FROM scratch` image possible: there is no
filesystem in the final image to read them from.

## Layout

```
cmd/details      book metadata, canned or from the Google Books API
cmd/ratings      per-reviewer star ratings, held in memory
cmd/reviews      book reviews, optionally decorated with stars
cmd/productpage  the front end and the public JSON API
internal/bookinfo  the serving, header-propagation and JSON helpers they share
```

Each service is a single `main.go` with its `Dockerfile` beside it. All four
build from one Go module rooted at this directory, which is why the Docker
build context is `samples/bookinfo-v2` rather than the individual service
directory.

## Building

Same interface as the original:

```bash
BOOKINFO_HUB=localhost:5000 BOOKINFO_TAG=dev ./build-services.sh --load
```

`docker-bake.hcl` produces the same image names and version arguments as
[the original](../bookinfo/src/docker-bake.hcl), minus the three noted below.

## Running locally

Each binary takes an optional port, defaulting to 9080:

```bash
go run ./cmd/details  9081 &
go run ./cmd/ratings  9082 &
ENABLE_RATINGS=true RATINGS_SERVICE_PORT=9082 go run ./cmd/reviews 9083 &
DETAILS_SERVICE_PORT=9081 REVIEWS_SERVICE_PORT=9083 RATINGS_SERVICE_PORT=9082 \
  DETAILS_HOSTNAME=localhost REVIEWS_HOSTNAME=localhost RATINGS_HOSTNAME=localhost \
  go run ./cmd/productpage 9080
```

## Tests

```bash
go test ./...
```

The product page tests cover HTTP behavior, backend calls, metrics and session
handling without requiring byte-for-byte HTML parity with the original app.
The backend tests assert the exact response bodies the Ruby, JavaScript and
Java services emitted, including key order.

## Deliberately preserved quirks

A drop-in replacement has to reproduce the bugs too, because the Istio tasks
built on this sample depend on some of them.

- **The product page retries reviews twice.** The fault injection task relies
  on the second attempt; see the comment in `cmd/productpage/main.go`.
- **`reviews` reports an unset `CLUSTER_NAME` as the string `"null"`.** That is
  what the Java version serialized, and the product page template keys off it
  to decide whether to show a cluster name.
- **The reviews container div has an unterminated `class` attribute.** Closing
  the quote would change the page layout, because browsers currently swallow
  the `<div class="max-w-2xl">` that follows it. `html/template` refuses to
  parse the malformed tag, so it is emitted from Go instead; see
  `unclosedReviewsContainer` in `cmd/productpage/view.go`.
- **The landing page labels the root of the service table with the details
  URL.** Reproduced in `serviceTable`, same file.
- **`ratings` accepts a product id with trailing junk.** The original route
  regex was unanchored and `parseInt` took the leading digits, so `/ratings/1x`
  asks for product 1 and `/ratings/abc` is a 400 rather than a 404.
- **`details` keys off the last path segment**, so `/details/1/2` asks for
  book 2.

## What is not here

The database-backed variants are out of scope, so this directory has no
counterpart to the original `examples-bookinfo-ratings-v2`,
`examples-bookinfo-mysqldb` or `examples-bookinfo-mongodb` images. Bringing
them back would mean a database driver, and that is the dependency this
rewrite is about avoiding. Use the original sample for the tasks that need
them.
