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

// Command productpage serves the BookInfo front end and the public JSON API.
// It owns no data of its own: everything on the page is stitched together
// from the details, reviews and ratings services.
package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"

	"istio.io/bookinfo/internal/bookinfo"
)

//go:embed templates
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

// backendTimeout matches the reference implementation. It is deliberately
// shorter than the delays injected by the ratings v-delayed version.
const backendTimeout = 3 * time.Second

// sessionCookie holds the signed-in user name. There is no password check;
// the sample uses it only to attach an end-user header to outbound requests
// so the request routing tasks have something to match on.
const sessionCookie = "session"

// backend is one of the services the product page calls. The endpoint path
// segment happens to equal the service name for all of them.
type backend struct {
	app     string
	baseURL string
	// attempts is how many times to try before giving up.
	attempts int
	// failure is the message returned to the caller when every attempt fails.
	failure string
}

func (b backend) url(productID string) string {
	return b.baseURL + "/" + b.app + "/" + url.PathEscape(productID)
}

type server struct {
	details backend
	reviews backend
	ratings backend

	// floodFactor is the number of extra, discarded review requests to fire
	// on every page load, used to demonstrate rate limiting.
	floodFactor int

	client    *http.Client
	templates *template.Template
	counter   *resultCounter
}

func main() {
	log.SetFlags(0)

	port, err := bookinfo.PortFromArgs(os.Args)
	if err != nil {
		log.Fatalf("productpage: %v", err)
	}

	s, err := newServer()
	if err != nil {
		log.Fatalf("productpage: %v", err)
	}

	if err := bookinfo.Run(port, s.routes()); err != nil {
		log.Fatalf("productpage: %v", err)
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /index.html", s.handleIndex)
	mux.HandleFunc("GET /health", handleHealth)
	mux.HandleFunc("POST /login", handleLogin)
	mux.HandleFunc("GET /logout", handleLogout)
	mux.HandleFunc("GET /productpage", s.handleProductPage)
	mux.HandleFunc("GET /metrics", s.handleMetrics)
	mux.HandleFunc("GET /api/v1/products", handleProducts)
	mux.HandleFunc("GET /api/v1/products/{productID}", s.proxy(s.details))
	mux.HandleFunc("GET /api/v1/products/{productID}/reviews", s.proxy(s.reviews))
	mux.HandleFunc("GET /api/v1/products/{productID}/ratings", s.proxy(s.ratings))
	mux.Handle("GET /static/", http.FileServerFS(staticFS))
	return mux
}

func newServer() (*server, error) {
	servicesDomain := ""
	if domain := os.Getenv("SERVICES_DOMAIN"); domain != "" {
		servicesDomain = "." + domain
	}
	baseURL := func(hostVar, portVar, defaultHost string) string {
		return fmt.Sprintf("http://%s%s:%s",
			bookinfo.Env(hostVar, defaultHost), servicesDomain, bookinfo.Env(portVar, "9080"))
	}

	floodFactor := 0
	if raw := os.Getenv("FLOOD_FACTOR"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 0 {
			return nil, fmt.Errorf("invalid FLOOD_FACTOR %q: want a non-negative integer", raw)
		}
		floodFactor = parsed
	}

	templates, err := template.New("bookinfo").Funcs(templateFuncs).ParseFS(templateFS, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parsing templates: %w", err)
	}

	return &server{
		details: backend{
			app:      "details",
			baseURL:  baseURL("DETAILS_HOSTNAME", "DETAILS_SERVICE_PORT", "details"),
			attempts: 1,
			failure:  "Sorry, product details are currently unavailable for this book.",
		},
		reviews: backend{
			app:     "reviews",
			baseURL: baseURL("REVIEWS_HOSTNAME", "REVIEWS_SERVICE_PORT", "reviews"),
			// Do not reduce to one. This retry is here explicitly to
			// illustrate the fault injection task.
			attempts: 2,
			failure:  "Sorry, product reviews are currently unavailable for this book.",
		},
		ratings: backend{
			app:      "ratings",
			baseURL:  baseURL("RATINGS_HOSTNAME", "RATINGS_SERVICE_PORT", "ratings"),
			attempts: 1,
			failure:  "Sorry, product ratings are currently unavailable for this book.",
		},
		floodFactor: floodFactor,
		client:      bookinfo.NewClient(backendTimeout),
		templates:   templates,
		counter:     &resultCounter{},
	}, nil
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if _, err := io.WriteString(w, "Product page is healthy"); err != nil {
		log.Printf("writing health response: %v", err)
	}
}

func (s *server) handleIndex(w http.ResponseWriter, _ *http.Request) {
	s.render(w, "index.html", struct{ ServiceTable template.HTML }{
		ServiceTable: serviceTable(s.details.baseURL, s.reviews.baseURL, s.ratings.baseURL),
	})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    url.QueryEscape(r.FormValue("username")),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	redirectToReferrer(w, r)
}

func handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	redirectToReferrer(w, r)
}

// redirectToReferrer sends the browser back to the page the form was posted
// from, falling back to the product page for direct API callers.
func redirectToReferrer(w http.ResponseWriter, r *http.Request) {
	target := r.Referer()
	if target == "" {
		target = "/productpage"
	}
	http.Redirect(w, r, target, http.StatusFound)
}

// currentUser returns the signed-in user name, or the empty string. Control
// characters are dropped because the name is copied into an outbound header.
func currentUser(r *http.Request) string {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return ""
	}
	name, err := url.QueryUnescape(cookie.Value)
	if err != nil {
		return ""
	}
	for _, c := range []byte(name) {
		if c < 0x20 || c == 0x7f {
			return ""
		}
	}
	return name
}

func (s *server) handleProductPage(w http.ResponseWriter, r *http.Request) {
	const productID = "0" // TODO: replace default value

	headers := s.forwardHeaders(r)
	detailsStatus, detailsBody := s.fetch(r, s.details, productID, headers)

	if s.floodFactor > 0 {
		s.floodReviews(r, productID, headers)
	}

	reviewsStatus, reviewsBody := s.fetch(r, s.reviews, productID, headers)

	view := productPageView{
		DetailsStatus: detailsStatus,
		ReviewsStatus: reviewsStatus,
		Product:       products()[0],
		Details:       decodeDetails(detailsBody),
		Reviews:       decodeReviews(reviewsBody),
		User:          currentUser(r),
	}
	s.render(w, "productpage.html", view)
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.templates.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("rendering %s: %v", name, err)
	}
}

// proxy serves one of the /api/v1/products/{productID}/... routes by handing
// back whatever target replied with.
func (s *server) proxy(target backend) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		status, body := s.fetch(r, target, r.PathValue("productID"), s.forwardHeaders(r))
		bookinfo.WriteJSONBytes(w, status, body)
	}
}

func handleProducts(w http.ResponseWriter, _ *http.Request) {
	bookinfo.WriteJSON(w, http.StatusOK, products())
}

func (s *server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	if _, err := io.WriteString(w, s.counter.expose()); err != nil {
		log.Printf("writing metrics response: %v", err)
	}
}

func (s *server) forwardHeaders(r *http.Request) http.Header {
	headers := bookinfo.ForwardHeaders(r)
	// The end-user identity comes from our own session, never from the
	// caller.
	headers.Del("End-User")
	if user := currentUser(r); user != "" {
		headers.Set("End-User", user)
	}
	return headers
}

// fetch calls a backend and returns the status and JSON body the product page
// should report. Backend failures are turned into a JSON error document
// rather than propagated as Go errors: an unreachable backend is an expected
// state for this sample, and the page renders around it.
func (s *server) fetch(incoming *http.Request, target backend, productID string, headers http.Header) (int, []byte) {
	status := http.StatusInternalServerError
	for range target.attempts {
		var body []byte
		status, body = s.attempt(incoming, target, productID, headers)
		if status == http.StatusOK {
			s.counter.inc(target.app, status)
			return status, body
		}
	}

	s.counter.inc(target.app, status)
	failure, err := json.Marshal(map[string]string{"error": target.failure})
	if err != nil {
		// Marshalling a map of strings cannot fail.
		panic(err)
	}
	return status, failure
}

func (s *server) attempt(incoming *http.Request, target backend, productID string, headers http.Header) (int, []byte) {
	endpoint := target.url(productID)

	req, err := http.NewRequestWithContext(incoming.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		log.Printf("building request for %s: %v", endpoint, err)
		return http.StatusInternalServerError, nil
	}
	req.Header = headers

	res, err := s.client.Do(req)
	if err != nil {
		log.Printf("calling %s: %v", endpoint, err)
		return http.StatusInternalServerError, nil
	}
	defer res.Body.Close()

	body, err := io.ReadAll(res.Body)
	if err != nil {
		log.Printf("reading response from %s: %v", endpoint, err)
		return http.StatusInternalServerError, nil
	}
	return res.StatusCode, body
}

// floodReviews fires a burst of extra requests at the reviews service so the
// Istio rate limiting task has traffic to throttle. The responses are
// discarded.
func (s *server) floodReviews(incoming *http.Request, productID string, headers http.Header) {
	var wg sync.WaitGroup
	wg.Add(s.floodFactor)
	for range s.floodFactor {
		go func() {
			defer wg.Done()
			s.fetch(incoming, s.reviews, productID, headers)
		}()
	}
	wg.Wait()
}
