// Copyright Istio Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package bookinfo

import "net/http"

// A note on distributed tracing:
//
// Although Istio proxies are able to automatically send spans, they need some
// hints to tie together the entire trace. Applications need to propagate the
// appropriate HTTP headers so that when the proxies send span information, the
// spans can be correlated correctly into a single trace.
//
// To do this, an application needs to collect and propagate headers from the
// incoming request to any outgoing requests. The choice of headers to
// propagate is determined by the trace configuration used.
//
// For Zipkin, always propagate b3 headers.
// For Lightstep, always propagate the x-ot-span-context header.
// For Datadog, propagate the corresponding datadog headers.
// For OpenCensusAgent and Stackdriver configurations, you can choose any set
// of compatible headers to propagate within your application. For example, you
// can propagate b3 headers or W3C trace context headers with the same result.
// This can also allow you to translate between context propagation mechanisms
// between different applications.
var propagatedHeaders = []string{
	// All applications should propagate x-request-id. This header is included
	// in access log statements and is used for consistent trace sampling and
	// log sampling decisions in Istio.
	"x-request-id",

	// Lightstep tracing header. Propagate this if you use lightstep tracing in
	// Istio (see
	// https://istio.io/latest/docs/tasks/observability/distributed-tracing/lightstep/)
	// Note: this should probably be changed to use B3 or W3C TRACE_CONTEXT.
	// Lightstep recommends using B3 or TRACE_CONTEXT and most application
	// libraries from lightstep do not support x-ot-span-context.
	"x-ot-span-context",

	// Datadog tracing headers. Propagate these headers if you use Datadog
	// tracing.
	"x-datadog-trace-id",
	"x-datadog-parent-id",
	"x-datadog-sampling-priority",

	// W3C Trace Context. Compatible with OpenCensusAgent and Stackdriver Istio
	// configurations.
	"traceparent",
	"tracestate",

	// Cloud trace context. Compatible with OpenCensusAgent and Stackdriver
	// Istio configurations.
	"x-cloud-trace-context",

	// Grpc binary trace context. Compatible with OpenCensusAgent and
	// Stackdriver Istio configurations.
	"grpc-trace-bin",

	// b3 trace headers. Compatible with Zipkin, OpenCensusAgent, and
	// Stackdriver Istio configurations.
	"x-b3-traceid",
	"x-b3-spanid",
	"x-b3-parentspanid",
	"x-b3-sampled",
	"x-b3-flags",

	// SkyWalking trace headers.
	"sw8",

	// Application-specific headers to forward.
	"end-user",
	"user-agent",

	// Context and session specific headers.
	"cookie",
	"authorization",
	"jwt",
}

// ForwardHeaders returns the subset of r's headers that must be copied onto
// any request made while serving r, so that Istio can stitch the resulting
// proxy spans into a single trace.
func ForwardHeaders(r *http.Request) http.Header {
	out := make(http.Header, len(propagatedHeaders))
	for _, name := range propagatedHeaders {
		if values, ok := r.Header[http.CanonicalHeaderKey(name)]; ok {
			out[http.CanonicalHeaderKey(name)] = values
		}
	}
	return out
}
