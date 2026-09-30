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

package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"istio.io/bookinfo/internal/bookinfo"
)

const (
	reviewOne = "An extremely entertaining play by Shakespeare. The slapstick humour is refreshing!"
	reviewTwo = "Absolutely fun and entertaining. The play lacks thematic depth when compared to other plays by Shakespeare."
)

// The expected bodies below are what the Java implementation emitted, down to
// the key order and the quoted id.
func TestReviewsResponsesMatchReferenceImplementation(t *testing.T) {
	t.Parallel()

	ratings := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		bookinfo.WriteJSON(w, http.StatusOK, map[string]any{"id": 0, "ratings": map[string]int{"Reviewer1": 5, "Reviewer2": 4}})
	}))
	t.Cleanup(ratings.Close)

	unreachable := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(unreachable.Close)

	tests := []struct {
		name   string
		server *server
		path   string
		status int
		body   string
	}{
		{
			name:   "health",
			server: &server{},
			path:   "/health",
			status: http.StatusOK,
			body:   `{"status":"Reviews is healthy"}`,
		},
		{
			// v1 has no ratings at all, so the reviews carry no rating key.
			name:   "ratings disabled",
			server: &server{clusterName: "null"},
			path:   "/reviews/0",
			status: http.StatusOK,
			body: `{"id":"0","podname":"","clustername":"null","reviews":[` +
				`{"reviewer":"Reviewer1","text":"` + reviewOne + `"},` +
				`{"reviewer":"Reviewer2","text":"` + reviewTwo + `"}]}`,
		},
		{
			name: "black stars from v2",
			server: &server{
				ratingsEnabled: true, starColor: "black", ratingsService: ratings.URL,
				podName: "reviews-v2-def456", clusterName: "cluster-1",
			},
			path:   "/reviews/0",
			status: http.StatusOK,
			body: `{"id":"0","podname":"reviews-v2-def456","clustername":"cluster-1","reviews":[` +
				`{"reviewer":"Reviewer1","text":"` + reviewOne + `","rating":{"stars":5,"color":"black"}},` +
				`{"reviewer":"Reviewer2","text":"` + reviewTwo + `","rating":{"stars":4,"color":"black"}}]}`,
		},
		{
			// A ratings outage is reported per review rather than failing the
			// whole response.
			name: "ratings service down",
			server: &server{
				ratingsEnabled: true, starColor: "red", ratingsService: unreachable.URL,
				podName: "reviews-v3-abc123", clusterName: "null",
			},
			path:   "/reviews/0",
			status: http.StatusOK,
			body: `{"id":"0","podname":"reviews-v3-abc123","clustername":"null","reviews":[` +
				`{"reviewer":"Reviewer1","text":"` + reviewOne + `","rating":{"error":"Ratings service is currently unavailable"}},` +
				`{"reviewer":"Reviewer2","text":"` + reviewTwo + `","rating":{"error":"Ratings service is currently unavailable"}}]}`,
		},
		{
			name:   "non numeric product id",
			server: &server{},
			path:   "/reviews/abc",
			status: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			tt.server.client = bookinfo.NewClient(5 * time.Second)

			recorder := httptest.NewRecorder()
			tt.server.routes().ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if recorder.Code != tt.status {
				t.Errorf("status = %d, want %d", recorder.Code, tt.status)
			}
			if tt.body == "" {
				return
			}
			if got := recorder.Body.String(); got != tt.body+"\n" {
				t.Errorf("body = %s, want %s", got, tt.body)
			}
		})
	}
}

// The reviews service identifies the caller to the ratings service so that the
// request routing tasks can match on the header.
func TestRatingsRequestCarriesTheTracingAndUserHeaders(t *testing.T) {
	t.Parallel()

	var seen http.Header
	ratings := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Clone()
		bookinfo.WriteJSON(w, http.StatusOK, map[string]any{"ratings": map[string]int{}})
	}))
	t.Cleanup(ratings.Close)

	s := &server{
		ratingsEnabled: true, starColor: "black", ratingsService: ratings.URL,
		client: bookinfo.NewClient(5 * time.Second),
	}

	req := httptest.NewRequest(http.MethodGet, "/reviews/0", nil)
	req.Header.Set("End-User", "jason")
	req.Header.Set("X-B3-Traceid", "abc123")
	req.Header.Set("X-Not-Propagated", "secret")
	s.routes().ServeHTTP(httptest.NewRecorder(), req)

	if got := seen.Get("End-User"); got != "jason" {
		t.Errorf("End-User = %q, want jason", got)
	}
	if got := seen.Get("X-B3-Traceid"); got != "abc123" {
		t.Errorf("X-B3-Traceid = %q, want abc123", got)
	}
	if got := seen.Get("X-Not-Propagated"); got != "" {
		t.Errorf("X-Not-Propagated = %q, want it to be dropped", got)
	}
}

func TestReviewsSurvivesASlowRatingsService(t *testing.T) {
	t.Parallel()

	ratings := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(time.Minute):
		case <-r.Context().Done():
		}
		_, _ = io.WriteString(w, "{}")
	}))
	t.Cleanup(ratings.Close)

	s := &server{
		ratingsEnabled: true, starColor: "red", ratingsService: ratings.URL, clusterName: "null",
		client: bookinfo.NewClient(50 * time.Millisecond),
	}

	recorder := httptest.NewRecorder()
	s.routes().ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/reviews/0", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	const want = "Ratings service is currently unavailable"
	if got := recorder.Body.String(); !strings.Contains(got, want) {
		t.Errorf("body = %s, want it to report %q", got, want)
	}
}
