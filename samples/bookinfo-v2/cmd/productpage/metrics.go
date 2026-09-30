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
	"fmt"
	"slices"
	"strings"
	"sync"
)

// resultCounter is the request_result Prometheus counter: one series per
// backend and response code pair. A dedicated counter is all the product page
// needs, so it renders the exposition format itself rather than taking on a
// metrics library.
type resultCounter struct {
	mu     sync.Mutex
	counts map[resultLabels]uint64
}

type resultLabels struct {
	destinationApp string
	responseCode   int
}

func (c *resultCounter) inc(destinationApp string, responseCode int) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.counts == nil {
		c.counts = map[resultLabels]uint64{}
	}
	c.counts[resultLabels{destinationApp, responseCode}]++
}

// expose renders the counter in the Prometheus text exposition format.
// Series are sorted so that scrapes and diffs are stable.
func (c *resultCounter) expose() string {
	type series struct {
		resultLabels
		count uint64
	}

	c.mu.Lock()
	all := make([]series, 0, len(c.counts))
	for label, count := range c.counts {
		all = append(all, series{label, count})
	}
	c.mu.Unlock()

	slices.SortFunc(all, func(a, b series) int {
		if byApp := strings.Compare(a.destinationApp, b.destinationApp); byApp != 0 {
			return byApp
		}
		return a.responseCode - b.responseCode
	})

	var out strings.Builder
	out.WriteString("# HELP request_result_total Results of requests\n")
	out.WriteString("# TYPE request_result_total counter\n")
	for _, s := range all {
		fmt.Fprintf(&out, "request_result_total{destination_app=%q,response_code=\"%d\"} %d\n",
			s.destinationApp, s.responseCode, s.count)
	}
	return out.String()
}
