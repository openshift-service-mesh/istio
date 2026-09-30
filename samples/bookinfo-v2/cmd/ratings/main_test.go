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
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() *server {
	return &server{userAdded: map[int]map[string]int{}, healthy: true}
}

// The expected bodies below are what the JavaScript implementation emitted.
func TestRatingsResponsesMatchReferenceImplementation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		method string
		path   string
		status int
		body   string
	}{
		{
			name:   "health",
			method: http.MethodGet,
			path:   "/health",
			status: http.StatusOK,
			body:   `{"status":"Ratings is healthy"}`,
		},
		{
			name:   "default ratings",
			method: http.MethodGet,
			path:   "/ratings/0",
			status: http.StatusOK,
			body:   `{"id":0,"ratings":{"Reviewer1":5,"Reviewer2":4}}`,
		},
		{
			// parseInt in the reference implementation took the leading
			// digits and ignored the rest.
			name:   "trailing junk after the digits",
			method: http.MethodGet,
			path:   "/ratings/1x",
			status: http.StatusOK,
			body:   `{"id":1,"ratings":{"Reviewer1":5,"Reviewer2":4}}`,
		},
		{
			// The route regex was unanchored, so a non numeric id reached the
			// handler and was rejected rather than 404ing.
			name:   "non numeric id",
			method: http.MethodGet,
			path:   "/ratings/abc",
			status: http.StatusBadRequest,
			body:   `{"error":"please provide numeric product ID"}`,
		},
		{
			name:   "invalid body on POST",
			method: http.MethodPost,
			path:   "/ratings/0",
			status: http.StatusBadRequest,
			body:   `{"error":"please provide valid ratings JSON"}`,
		},
	}

	routes := newTestServer().routes()

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			recorder := httptest.NewRecorder()
			routes.ServeHTTP(recorder, httptest.NewRequest(tt.method, tt.path, strings.NewReader("not json")))

			if recorder.Code != tt.status {
				t.Errorf("status = %d, want %d", recorder.Code, tt.status)
			}
			if got := recorder.Body.String(); got != tt.body+"\n" {
				t.Errorf("body = %s, want %s", got, tt.body)
			}
		})
	}
}

func TestPostedRatingsReplaceTheDefaultsForThatProductOnly(t *testing.T) {
	t.Parallel()

	routes := newTestServer().routes()

	post := httptest.NewRecorder()
	routes.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/ratings/0",
		strings.NewReader(`{"Reviewer1":1,"Reviewer2":2}`)))

	const want = `{"id":0,"ratings":{"Reviewer1":1,"Reviewer2":2}}` + "\n"
	if got := post.Body.String(); got != want {
		t.Errorf("POST body = %s, want %s", got, want)
	}

	get := httptest.NewRecorder()
	routes.ServeHTTP(get, httptest.NewRequest(http.MethodGet, "/ratings/0", nil))
	if got := get.Body.String(); got != want {
		t.Errorf("GET body after POST = %s, want %s", got, want)
	}

	other := httptest.NewRecorder()
	routes.ServeHTTP(other, httptest.NewRequest(http.MethodGet, "/ratings/1", nil))
	const wantOther = `{"id":1,"ratings":{"Reviewer1":5,"Reviewer2":4}}` + "\n"
	if got := other.Body.String(); got != wantOther {
		t.Errorf("GET body for another product = %s, want %s", got, wantOther)
	}
}

func TestUnavailableVariantsFailWhileTheyAreFlippedOff(t *testing.T) {
	t.Parallel()

	for _, v := range []variant{unavailableVariant, unhealthyVariant} {
		t.Run(string(v), func(t *testing.T) {
			t.Parallel()

			s := newTestServer()
			s.variant = v
			// Rather than wait out the timer, flip the state the timer drives.
			s.unavailable = true
			s.healthy = v != unhealthyVariant
			routes := s.routes()

			ratings := httptest.NewRecorder()
			routes.ServeHTTP(ratings, httptest.NewRequest(http.MethodGet, "/ratings/0", nil))
			if ratings.Code != http.StatusServiceUnavailable {
				t.Errorf("ratings status = %d, want %d", ratings.Code, http.StatusServiceUnavailable)
			}

			// Only the unhealthy variant reports the outage on /health; the
			// unavailable one stays healthy so Kubernetes leaves it running.
			wantHealth := http.StatusOK
			if v == unhealthyVariant {
				wantHealth = http.StatusInternalServerError
			}
			health := httptest.NewRecorder()
			routes.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/health", nil))
			if health.Code != wantHealth {
				t.Errorf("health status = %d, want %d", health.Code, wantHealth)
			}
		})
	}
}
