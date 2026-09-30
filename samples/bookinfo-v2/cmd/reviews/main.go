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

// Command reviews serves book reviews, optionally decorated with stars
// fetched from the ratings service.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"istio.io/bookinfo/internal/bookinfo"
)

// reviewTexts are fixed; the reviews versions differ only in whether they show
// ratings and in what colour.
var reviewTexts = []struct{ Reviewer, Text string }{
	{"Reviewer1", "An extremely entertaining play by Shakespeare. The slapstick humour is refreshing!"},
	{"Reviewer2", "Absolutely fun and entertaining. The play lacks thematic depth when compared to other plays by Shakespeare."},
}

type reviewsResponse struct {
	// ID is a string because the reference implementation hand-rolled its
	// JSON and quoted the product id.
	ID          string   `json:"id"`
	PodName     string   `json:"podname"`
	ClusterName string   `json:"clustername"`
	Reviews     []review `json:"reviews"`
}

type review struct {
	Reviewer string `json:"reviewer"`
	Text     string `json:"text"`
	// Rating is a starRating, a ratingError, or absent when ratings are
	// disabled for this version.
	Rating any `json:"rating,omitempty"`
}

type starRating struct {
	Stars int    `json:"stars"`
	Color string `json:"color"`
}

type ratingError struct {
	Error string `json:"error"`
}

type server struct {
	ratingsEnabled bool
	starColor      string
	ratingsService string
	podName        string
	clusterName    string
	client         *http.Client
}

func main() {
	log.SetFlags(0)

	port, err := bookinfo.PortFromArgs(os.Args)
	if err != nil {
		log.Fatalf("reviews: %v", err)
	}

	starColor := bookinfo.Env("STAR_COLOR", "black")
	// The v1/v2 deployments get a generous timeout; v3 (red stars) uses a
	// tight one so the circuit breaking and timeout tasks have something to
	// trip.
	timeout := 10 * time.Second
	if starColor != "black" {
		timeout = 2500 * time.Millisecond
	}

	servicesDomain := ""
	if domain := os.Getenv("SERVICES_DOMAIN"); domain != "" {
		servicesDomain = "." + domain
	}

	s := &server{
		ratingsEnabled: bookinfo.EnvIsTrue("ENABLE_RATINGS"),
		starColor:      starColor,
		ratingsService: fmt.Sprintf("http://%s%s:%s/ratings",
			bookinfo.Env("RATINGS_HOSTNAME", "ratings"),
			servicesDomain,
			bookinfo.Env("RATINGS_SERVICE_PORT", "9080")),
		podName: os.Getenv("HOSTNAME"),
		// The product page hides the cluster name when it is the literal
		// string "null", which is what the Java version printed for an unset
		// CLUSTER_NAME.
		clusterName: bookinfo.Env("CLUSTER_NAME", "null"),
		client:      bookinfo.NewClient(timeout),
	}

	if err := bookinfo.Run(port, s.routes()); err != nil {
		log.Fatalf("reviews: %v", err)
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", handleHealth)
	mux.HandleFunc("GET /reviews/{productID}", s.handleReviews)
	return mux
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	bookinfo.WriteJSON(w, http.StatusOK, map[string]string{"status": "Reviews is healthy"})
}

func (s *server) handleReviews(w http.ResponseWriter, r *http.Request) {
	productID, err := strconv.Atoi(r.PathValue("productID"))
	if err != nil {
		http.NotFound(w, r)
		return
	}

	var stars map[string]int
	if s.ratingsEnabled {
		stars = s.fetchRatings(r, productID)
	}

	response := reviewsResponse{
		ID:          strconv.Itoa(productID),
		PodName:     s.podName,
		ClusterName: s.clusterName,
		Reviews:     make([]review, 0, len(reviewTexts)),
	}
	for _, text := range reviewTexts {
		response.Reviews = append(response.Reviews, review{
			Reviewer: text.Reviewer,
			Text:     text.Text,
			Rating:   s.ratingFor(stars, text.Reviewer),
		})
	}
	bookinfo.WriteJSON(w, http.StatusOK, response)
}

func (s *server) ratingFor(stars map[string]int, reviewer string) any {
	if !s.ratingsEnabled {
		return nil
	}
	if count, ok := stars[reviewer]; ok {
		return starRating{Stars: count, Color: s.starColor}
	}
	return ratingError{Error: "Ratings service is currently unavailable"}
}

// fetchRatings returns the stars keyed by reviewer, or nil if the ratings
// service could not be reached. A failure is not fatal: the reviews are still
// served, with an error in place of the stars.
func (s *server) fetchRatings(incoming *http.Request, productID int) map[string]int {
	endpoint := fmt.Sprintf("%s/%d", s.ratingsService, productID)

	req, err := http.NewRequestWithContext(incoming.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		log.Printf("Error: unable to build request for %s: %v", endpoint, err)
		return nil
	}
	req.Header = bookinfo.ForwardHeaders(incoming)
	req.Header.Set("Accept", "application/json")

	res, err := s.client.Do(req)
	if err != nil {
		log.Printf("Error: unable to contact %s got exception %v", s.ratingsService, err)
		return nil
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK {
		log.Printf("Error: unable to contact %s got status of %d", s.ratingsService, res.StatusCode)
		return nil
	}

	var body struct {
		Ratings map[string]int `json:"ratings"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		log.Printf("Error: unable to parse response from %s: %v", s.ratingsService, err)
		return nil
	}
	return body.Ratings
}
