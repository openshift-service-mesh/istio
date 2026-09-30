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

// Command ratings serves per-reviewer star ratings from memory.
//
// SERVICE_VERSION selects one of several deliberately misbehaving variants
// used by the resilience and observability tasks.
package main

import (
	"encoding/json"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"istio.io/bookinfo/internal/bookinfo"
)

// variant is the behaviour selected by SERVICE_VERSION.
type variant string

const (
	// healthyVariant always answers successfully. Used by v1 and any
	// unrecognised SERVICE_VERSION.
	healthyVariant variant = ""
	// faultyVariant fails half of the requests.
	faultyVariant variant = "v-faulty"
	// delayedVariant stalls half of the requests.
	delayedVariant variant = "v-delayed"
	// unavailableVariant flips between working and failing every minute.
	unavailableVariant variant = "v-unavailable"
	// unhealthyVariant flips between working and failing every fifteen
	// minutes, and reports the outage on /health too.
	unhealthyVariant variant = "v-unhealthy"
)

// faultDelay is how long delayedVariant stalls a request for. It is longer
// than the product page's three second timeout on purpose.
const faultDelay = 7 * time.Second

// defaultRatings is what every product scores until a POST overrides it.
var defaultRatings = map[string]int{"Reviewer1": 5, "Reviewer2": 4}

// ratings is the response body of both the GET and POST endpoints.
type ratings struct {
	ID      int            `json:"id"`
	Ratings map[string]int `json:"ratings"`
}

type server struct {
	variant variant

	mu sync.RWMutex
	// userAdded holds ratings submitted over POST, demonstrating that the
	// service is writable.
	userAdded map[int]map[string]int
	// unavailable and healthy are flipped on a timer by the unavailable and
	// unhealthy variants.
	unavailable bool
	healthy     bool
}

func main() {
	log.SetFlags(0)

	port, err := bookinfo.PortFromArgs(os.Args)
	if err != nil {
		log.Fatalf("ratings: %v", err)
	}

	s := &server{
		variant:   variant(os.Getenv("SERVICE_VERSION")),
		userAdded: map[int]map[string]int{},
		healthy:   true,
	}
	s.startFaultTimer()

	if err := bookinfo.Run(port, s.routes()); err != nil {
		log.Fatalf("ratings: %v", err)
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ratings/", s.handleGet)
	mux.HandleFunc("POST /ratings/", s.handlePost)
	return mux
}

// startFaultTimer drives the variants whose behaviour changes over time. The
// ticker lives for the lifetime of the process by design.
func (s *server) startFaultTimer() {
	var period time.Duration
	switch s.variant {
	case unavailableVariant:
		period = time.Minute
	case unhealthyVariant:
		// Fifteen minutes is chosen because Kubernetes resets its exponential
		// back-off after ten minutes of successful execution, see
		// https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#restart-policy
		// Kiali shows the last 10 or 30 minutes, so showing a 50% error rate
		// needs 30 minutes of running, 15 in each state.
		period = 15 * time.Minute
	default:
		return
	}

	go func() {
		for range time.Tick(period) {
			s.mu.Lock()
			s.unavailable = !s.unavailable
			if s.variant == unhealthyVariant {
				s.healthy = !s.healthy
			}
			s.mu.Unlock()
		}
	}()
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	healthy := s.healthy
	s.mu.RUnlock()

	if !healthy {
		bookinfo.WriteJSON(w, http.StatusInternalServerError, map[string]string{"status": "Ratings is not healthy"})
		return
	}
	bookinfo.WriteJSON(w, http.StatusOK, map[string]string{"status": "Ratings is healthy"})
}

func (s *server) handleGet(w http.ResponseWriter, r *http.Request) {
	id, ok := productID(r)
	if !ok {
		bookinfo.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": "please provide numeric product ID"})
		return
	}

	switch {
	case s.variant == faultyVariant && rand.IntN(2) == 0:
		bookinfo.WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "Service unavailable"})
		return
	case s.variant == delayedVariant && rand.IntN(2) == 0:
		select {
		case <-time.After(faultDelay):
		case <-r.Context().Done():
			return
		}
	case s.variant == unavailableVariant || s.variant == unhealthyVariant:
		s.mu.RLock()
		unavailable := s.unavailable
		s.mu.RUnlock()
		if unavailable {
			bookinfo.WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "Service unavailable"})
			return
		}
	}

	bookinfo.WriteJSON(w, http.StatusOK, s.ratingsFor(id))
}

func (s *server) handlePost(w http.ResponseWriter, r *http.Request) {
	id, ok := productID(r)
	if !ok {
		bookinfo.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": "please provide numeric product ID"})
		return
	}

	var submitted map[string]int
	if err := json.NewDecoder(r.Body).Decode(&submitted); err != nil {
		bookinfo.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": "please provide valid ratings JSON"})
		return
	}

	s.mu.Lock()
	s.userAdded[id] = submitted
	s.mu.Unlock()

	bookinfo.WriteJSON(w, http.StatusOK, s.ratingsFor(id))
}

func (s *server) ratingsFor(id int) ratings {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if stored, ok := s.userAdded[id]; ok {
		return ratings{ID: id, Ratings: stored}
	}
	return ratings{ID: id, Ratings: defaultRatings}
}

// productID reads the product from the last path segment the way the original
// JavaScript did: parseInt takes the leading digits and ignores any trailing
// junk, so /ratings/1x asks for product 1 and /ratings/x is rejected.
func productID(r *http.Request) (int, bool) {
	segments := strings.Split(r.URL.Path, "/")
	raw := segments[len(segments)-1]

	digits := 0
	for digits < len(raw) && raw[digits] >= '0' && raw[digits] <= '9' {
		digits++
	}
	if digits == 0 {
		return 0, false
	}
	id, err := strconv.Atoi(raw[:digits])
	if err != nil {
		return 0, false
	}
	return id, true
}
