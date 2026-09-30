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

// Command details serves book metadata, either canned or looked up from the
// Google Books API.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"istio.io/bookinfo/internal/bookinfo"
)

// The ISBN of one of the printings of The Comedy of Errors on Amazon that has
// Shakespeare as the single author.
const comedyOfErrorsISBN = "0486424618"

const externalTimeout = 5 * time.Second

// book is the details payload. Field order matches the Ruby implementation so
// that responses are byte for byte comparable.
// Year is an int for the canned response and the publication date string
// reported by the Google Books API for the external one.
type book struct {
	ID        int    `json:"id"`
	Author    string `json:"author"`
	Year      any    `json:"year"`
	Type      string `json:"type"`
	Pages     int    `json:"pages"`
	Publisher string `json:"publisher"`
	Language  string `json:"language"`
	ISBN10    string `json:"ISBN-10"`
	ISBN13    string `json:"ISBN-13"`
}

// errInvalidID is reported verbatim to clients, so keep the wording stable.
var errInvalidID = errors.New("please provide numeric product id")

type server struct {
	// externalService makes the service call the Google Books API instead of
	// returning canned details.
	externalService bool
	// encrypted selects HTTPS over HTTP for the external call. Unless
	// DO_NOT_ENCRYPT is set the app uses TLS to reach external services.
	encrypted bool
	client    *http.Client
}

func main() {
	log.SetFlags(0)

	port, err := bookinfo.PortFromArgs(os.Args)
	if err != nil {
		log.Fatalf("details: %v", err)
	}

	s := &server{
		externalService: bookinfo.EnvIsTrue("ENABLE_EXTERNAL_BOOK_SERVICE"),
		encrypted:       !bookinfo.EnvIsTrue("DO_NOT_ENCRYPT"),
		client:          bookinfo.NewClient(externalTimeout),
	}

	if err := bookinfo.Run(port, s.routes()); err != nil {
		log.Fatalf("details: %v", err)
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/details/", s.handleDetails)
	return mux
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	bookinfo.WriteJSON(w, http.StatusOK, map[string]string{"status": "Details is healthy"})
}

func (s *server) handleDetails(w http.ResponseWriter, r *http.Request) {
	details, err := s.lookup(r)
	if err != nil {
		log.Printf("details lookup failed: %v", err)
		bookinfo.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	bookinfo.WriteJSON(w, http.StatusOK, details)
}

func (s *server) lookup(r *http.Request) (book, error) {
	// The reference implementation keys off the last path segment, so
	// /details/1/2 asks for book 2.
	segments := strings.Split(r.URL.Path, "/")
	id, err := strconv.Atoi(segments[len(segments)-1])
	if err != nil {
		return book{}, errInvalidID
	}

	if !s.externalService {
		// TODO: provide details on different books.
		return book{
			ID:        id,
			Author:    "William Shakespeare",
			Year:      1595,
			Type:      "paperback",
			Pages:     200,
			Publisher: "PublisherA",
			Language:  "English",
			ISBN10:    "1234567890",
			ISBN13:    "123-1234567890",
		}, nil
	}
	return s.fetchExternal(r, id)
}

// volumes is the subset of the Google Books API response the sample needs.
type volumes struct {
	Items []struct {
		VolumeInfo volumeInfo `json:"volumeInfo"`
	} `json:"items"`
}

type volumeInfo struct {
	Authors             []string             `json:"authors"`
	PublishedDate       string               `json:"publishedDate"`
	PrintType           string               `json:"printType"`
	PageCount           int                  `json:"pageCount"`
	Publisher           string               `json:"publisher"`
	Language            string               `json:"language"`
	IndustryIdentifiers []industryIdentifier `json:"industryIdentifiers"`
}

type industryIdentifier struct {
	Type       string `json:"type"`
	Identifier string `json:"identifier"`
}

func (s *server) fetchExternal(incoming *http.Request, id int) (book, error) {
	scheme := "https"
	if !s.encrypted {
		scheme = "http"
	}
	endpoint := fmt.Sprintf("%s://www.googleapis.com/books/v1/volumes?q=%s",
		scheme, url.QueryEscape("isbn:"+comedyOfErrorsISBN))

	req, err := http.NewRequestWithContext(incoming.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		return book{}, fmt.Errorf("building request for %s: %w", endpoint, err)
	}
	req.Header = bookinfo.ForwardHeaders(incoming)

	res, err := s.client.Do(req)
	if err != nil {
		return book{}, fmt.Errorf("calling %s: %w", endpoint, err)
	}
	defer res.Body.Close()

	var parsed volumes
	if err := json.NewDecoder(res.Body).Decode(&parsed); err != nil {
		return book{}, fmt.Errorf("decoding response from %s: %w", endpoint, err)
	}
	if len(parsed.Items) == 0 {
		return book{}, fmt.Errorf("no volume found at %s for ISBN %s", endpoint, comedyOfErrorsISBN)
	}
	info := parsed.Items[0].VolumeInfo
	if len(info.Authors) == 0 {
		return book{}, fmt.Errorf("volume at %s for ISBN %s has no authors", endpoint, comedyOfErrorsISBN)
	}

	language := "unknown"
	if info.Language == "en" {
		language = "English"
	}
	printType := "unknown"
	if info.PrintType == "BOOK" {
		printType = "paperback"
	}

	return book{
		ID:        id,
		Author:    info.Authors[0],
		Year:      info.PublishedDate,
		Type:      printType,
		Pages:     info.PageCount,
		Publisher: info.Publisher,
		Language:  language,
		ISBN10:    isbn(info.IndustryIdentifiers, "ISBN_10"),
		ISBN13:    isbn(info.IndustryIdentifiers, "ISBN_13"),
	}, nil
}

func isbn(identifiers []industryIdentifier, want string) string {
	for _, identifier := range identifiers {
		if identifier.Type == want {
			return identifier.Identifier
		}
	}
	return ""
}
