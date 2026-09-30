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
	"testing"
)

// The expected bodies below are what the Ruby implementation emitted, down to
// the key order, so that the Go service is a drop-in replacement for callers
// that compare responses verbatim.
func TestDetailsResponsesMatchReferenceImplementation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		path   string
		status int
		body   string
	}{
		{
			name:   "health",
			path:   "/health",
			status: http.StatusOK,
			body:   `{"status":"Details is healthy"}`,
		},
		{
			name:   "canned details",
			path:   "/details/0",
			status: http.StatusOK,
			body: `{"id":0,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,` +
				`"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}`,
		},
		{
			name:   "the requested id is echoed back",
			path:   "/details/7",
			status: http.StatusOK,
			body: `{"id":7,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,` +
				`"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}`,
		},
		{
			name:   "non numeric id",
			path:   "/details/abc",
			status: http.StatusBadRequest,
			body:   `{"error":"please provide numeric product id"}`,
		},
		{
			name:   "missing id",
			path:   "/details/",
			status: http.StatusBadRequest,
			body:   `{"error":"please provide numeric product id"}`,
		},
		{
			// The reference implementation matched on the last path segment
			// only, so a nested path asks for the last id in it.
			name:   "nested path uses the last segment",
			path:   "/details/1/2",
			status: http.StatusOK,
			body: `{"id":2,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,` +
				`"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}`,
		},
	}

	routes := (&server{}).routes()

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			recorder := httptest.NewRecorder()
			routes.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if recorder.Code != tt.status {
				t.Errorf("status = %d, want %d", recorder.Code, tt.status)
			}
			if got := recorder.Body.String(); got != tt.body+"\n" {
				t.Errorf("body = %s, want %s", got, tt.body)
			}
		})
	}
}

func TestISBNPicksTheRequestedIdentifierType(t *testing.T) {
	t.Parallel()

	identifiers := []industryIdentifier{
		{Type: "ISBN_10", Identifier: "0486424618"},
		{Type: "ISBN_13", Identifier: "9780486424613"},
	}

	if got := isbn(identifiers, "ISBN_13"); got != "9780486424613" {
		t.Errorf("isbn(ISBN_13) = %q, want the thirteen digit identifier", got)
	}
	if got := isbn(identifiers, "OTHER"); got != "" {
		t.Errorf("isbn(OTHER) = %q, want an empty string for an absent type", got)
	}
}
