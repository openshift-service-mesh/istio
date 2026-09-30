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
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"

	"istio.io/bookinfo/internal/bookinfo"
)

// newTestServer builds a product page whose three backends all point at one
// stub. Each backend keeps the app name it reports in metrics and the failure
// message it falls back to.
func newTestServer(t *testing.T, stub http.Handler) *server {
	t.Helper()

	backendServer := httptest.NewServer(stub)
	t.Cleanup(backendServer.Close)

	named := func(app, failure string, attempts int) backend {
		return backend{app: app, baseURL: backendServer.URL, attempts: attempts, failure: failure}
	}
	return &server{
		details: named("details", "Sorry, product details are currently unavailable for this book.", 1),
		reviews: named("reviews", "Sorry, product reviews are currently unavailable for this book.", 2),
		ratings: named("ratings", "Sorry, product ratings are currently unavailable for this book.", 1),
		client:  bookinfo.NewClient(backendTimeout),
		templates: template.Must(template.New("bookinfo").
			Funcs(templateFuncs).ParseFS(templateFS, "templates/*.html")),
		counter: &resultCounter{},
	}
}

func TestAPIPassesBackendResponsesThrough(t *testing.T) {
	t.Parallel()

	stub := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bookinfo.WriteJSON(w, http.StatusOK, map[string]string{"path": r.URL.Path})
	})
	routes := newTestServer(t, stub).routes()

	tests := []struct {
		name string
		path string
		body string
	}{
		{name: "details", path: "/api/v1/products/0", body: `{"path":"/details/0"}`},
		{name: "reviews", path: "/api/v1/products/0/reviews", body: `{"path":"/reviews/0"}`},
		{name: "ratings", path: "/api/v1/products/0/ratings", body: `{"path":"/ratings/0"}`},
		{
			name: "products",
			path: "/api/v1/products",
			body: `[{"id":0,"title":"The Comedy of Errors","descriptionHtml":"` +
				`<a href=\"https://en.wikipedia.org/wiki/The_Comedy_of_Errors\">Wikipedia Summary</a>: ` +
				`The Comedy of Errors is one of <b>William Shakespeare's</b> early plays. It is his shortest ` +
				`and one of his most farcical comedies, with a major part of the humour coming from slapstick ` +
				`and mistaken identity, in addition to puns and word play."}]`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			recorder := httptest.NewRecorder()
			routes.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if recorder.Code != http.StatusOK {
				t.Errorf("status = %d, want %d", recorder.Code, http.StatusOK)
			}
			if got := recorder.Body.String(); got != tt.body+"\n" {
				t.Errorf("body = %s, want %s", got, tt.body)
			}
		})
	}
}

// An unreachable backend is a normal state for this sample; the API reports it
// as a JSON error rather than an empty body.
func TestAPIReportsBackendFailuresAsJSON(t *testing.T) {
	t.Parallel()

	stub := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	routes := newTestServer(t, stub).routes()

	recorder := httptest.NewRecorder()
	routes.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/v1/products/0", nil))

	if recorder.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
	const want = `{"error":"Sorry, product details are currently unavailable for this book."}`
	if got := recorder.Body.String(); got != want {
		t.Errorf("body = %s, want %s", got, want)
	}
}

// The retry exists only to make the fault injection task interesting, but the
// task depends on it, so pin it down.
func TestReviewsAreRetriedOnceAndDetailsAreNot(t *testing.T) {
	t.Parallel()

	var calls atomic.Int64
	stub := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	routes := newTestServer(t, stub).routes()

	for _, tc := range []struct {
		path string
		want int64
	}{
		{path: "/api/v1/products/0", want: 1},
		{path: "/api/v1/products/0/reviews", want: 2},
	} {
		calls.Store(0)
		routes.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, tc.path, nil))
		if got := calls.Load(); got != tc.want {
			t.Errorf("%s made %d backend calls, want %d", tc.path, got, tc.want)
		}
	}
}

func TestMetricsCountResultsPerBackend(t *testing.T) {
	t.Parallel()

	stub := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/reviews/") {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		bookinfo.WriteJSON(w, http.StatusOK, map[string]string{})
	})
	routes := newTestServer(t, stub).routes()

	for _, path := range []string{"/api/v1/products/0", "/api/v1/products/0", "/api/v1/products/0/reviews"} {
		routes.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}

	recorder := httptest.NewRecorder()
	routes.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	want := strings.Join([]string{
		"# HELP request_result_total Results of requests",
		"# TYPE request_result_total counter",
		`request_result_total{destination_app="details",response_code="200"} 2`,
		`request_result_total{destination_app="reviews",response_code="503"} 1`,
		"",
	}, "\n")
	if got := recorder.Body.String(); got != want {
		t.Errorf("metrics =\n%s\nwant\n%s", got, want)
	}
}

// Signing in is what makes the request routing tasks work: the user name is
// attached to every outbound call as end-user.
func TestSignedInUserIsForwardedAsTheEndUserHeader(t *testing.T) {
	t.Parallel()

	var seen string
	stub := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("End-User")
		bookinfo.WriteJSON(w, http.StatusOK, map[string]string{})
	})
	routes := newTestServer(t, stub).routes()

	login := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader("username=jason"))
	login.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	loggedIn := httptest.NewRecorder()
	routes.ServeHTTP(loggedIn, login)

	if loggedIn.Code != http.StatusFound {
		t.Fatalf("login status = %d, want %d", loggedIn.Code, http.StatusFound)
	}
	cookies := loggedIn.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != sessionCookie {
		t.Fatalf("login set %v, want a single %s cookie", cookies, sessionCookie)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/products/0", nil)
	req.AddCookie(cookies[0])
	// A caller supplied end-user header must not be able to impersonate.
	req.Header.Set("End-User", "attacker")
	routes.ServeHTTP(httptest.NewRecorder(), req)

	if seen != "jason" {
		t.Errorf("End-User = %q, want jason", seen)
	}
}

func TestSignedOutRequestsCarryNoEndUserHeader(t *testing.T) {
	t.Parallel()

	var seen string
	stub := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("End-User")
		bookinfo.WriteJSON(w, http.StatusOK, map[string]string{})
	})
	routes := newTestServer(t, stub).routes()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/products/0", nil)
	req.Header.Set("End-User", "attacker")
	routes.ServeHTTP(httptest.NewRecorder(), req)

	if seen != "" {
		t.Errorf("End-User = %q, want it to be dropped", seen)
	}
}

func TestCurrentUserRejectsNamesThatCannotGoInAHeader(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		value string
		want  string
	}{
		{name: "plain", value: url.QueryEscape("jason"), want: "jason"},
		{name: "spaces are legal", value: url.QueryEscape("jason smith"), want: "jason smith"},
		{name: "header injection", value: url.QueryEscape("jason\r\nX-Evil: 1"), want: ""},
		{name: "not escaped", value: "%zz", want: ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			r := httptest.NewRequest(http.MethodGet, "/productpage", nil)
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: tt.value})

			if got := currentUser(r); got != tt.want {
				t.Errorf("currentUser() = %q, want %q", got, tt.want)
			}
		})
	}
}
