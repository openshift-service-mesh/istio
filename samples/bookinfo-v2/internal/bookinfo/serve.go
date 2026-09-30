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

// Package bookinfo holds the handful of pieces every BookInfo service needs:
// trace header propagation, JSON replies, environment lookups and the server
// main loop.
package bookinfo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Port is the TCP port a BookInfo service listens on. All of them default to
// 9080 and accept an override as the single command line argument, matching
// the original Python/Ruby/Node/Java implementations.
type Port int

// PortFromArgs reads the listening port from args, which is expected to be
// os.Args. A missing argument yields the 9080 default.
func PortFromArgs(args []string) (Port, error) {
	if len(args) < 2 {
		return 9080, nil
	}
	p, err := strconv.Atoi(args[1])
	if err != nil || p < 1 || p > 65535 {
		return 0, fmt.Errorf("invalid port %q: want an integer in 1..65535", args[1])
	}
	return Port(p), nil
}

// Run serves handler until the process is asked to terminate, then drains
// in-flight requests. The listener is dual stack so the service works
// unchanged on IPv4-only, IPv6-only and dual stack clusters.
func Run(port Port, handler http.Handler) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	addr := net.JoinHostPort("", strconv.Itoa(int(port)))
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listening on %s: %w", addr, err)
	}

	server := &http.Server{
		Handler:           logRequests(handler),
		ReadHeaderTimeout: 10 * time.Second,
	}

	serveErr := make(chan error, 1)
	go func() {
		log.Printf("server listening on %s", listener.Addr())
		serveErr <- server.Serve(listener)
	}()

	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serving on %s: %w", addr, err)
	case <-ctx.Done():
		log.Print("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutting down server: %w", err)
	}
	return nil
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.RequestURI())
		next.ServeHTTP(w, r)
	})
}

// NewClient returns a client for calling another BookInfo service.
//
// Connections are deliberately not pooled so that load distribution across
// many versions of a backend is easy to observe in the traffic shifting tasks.
func NewClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DisableKeepAlives: true},
	}
}

// WriteJSON replies with v encoded as JSON.
//
// HTML escaping is off because the reference implementations do not escape
// either, and the product description the product page serves is HTML.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		log.Printf("writing JSON response: %v", err)
	}
}

// WriteJSONBytes replies with an already encoded JSON document.
func WriteJSONBytes(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if _, err := w.Write(body); err != nil {
		log.Printf("writing JSON response: %v", err)
	}
}

// Env returns the value of the environment variable name, or fallback when it
// is unset.
func Env(name, fallback string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return fallback
}

// EnvIsTrue reports whether the environment variable name is set to "true",
// ignoring case.
func EnvIsTrue(name string) bool {
	return strings.EqualFold(os.Getenv(name), "true")
}
