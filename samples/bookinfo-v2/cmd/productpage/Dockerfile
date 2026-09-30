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
# services share. The templates and static assets are embedded in the binary,
# so nothing but the binary needs to reach the final image.
FROM golang:1.27 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/productpage ./cmd/productpage

FROM scratch

COPY --from=build /out/productpage /productpage

ARG service_version
ENV SERVICE_VERSION=${service_version:-v1}
ARG flood_factor
ENV FLOOD_FACTOR=${flood_factor:-0}

EXPOSE 9080
USER 1000

ENTRYPOINT ["/productpage", "9080"]
