# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# The build context is samples/bookinfo-v2, the root of the module all four
# services share.
FROM golang:1.27 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/details ./cmd/details

FROM scratch

# v2 of this service looks books up over HTTPS, so it needs the trusted roots.
# Nothing else from the build image comes along.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/details /details

ARG service_version
ENV SERVICE_VERSION=${service_version:-v1}
ARG enable_external_book_service
ENV ENABLE_EXTERNAL_BOOK_SERVICE=${enable_external_book_service:-false}

EXPOSE 9080
USER 1000

ENTRYPOINT ["/details", "9080"]
