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
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
)

var templateFuncs = template.FuncMap{
	// comment emits an HTML comment. html/template drops comments written
	// literally in a template, and the reference page carries a few section
	// markers that are kept so the rendered HTML stays byte for byte the
	// same.
	"comment": func(text string) template.HTML {
		//nolint:gosec // The text is escaped on the way in.
		return template.HTML("<!-- " + template.HTMLEscapeString(text) + " -->")
	},

	// unclosedReviewsContainer emits the opening tag of the reviews section
	// exactly as the reference implementation wrote it, unterminated class
	// attribute and all. Browsers swallow the div that follows it, so closing
	// the quote would change the page layout; html/template in turn refuses
	// to parse the malformed tag, so it cannot live in the template file.
	"unclosedReviewsContainer": func() template.HTML {
		//nolint:gosec // Constant markup, no interpolation.
		return template.HTML(`<div class="container mx-auto px-4 sm:px-6 lg:px-8>`)
	},
}

// product is the only thing the product page knows first hand.
type product struct {
	ID              int           `json:"id"`
	Title           string        `json:"title"`
	DescriptionHTML template.HTML `json:"descriptionHtml"`
}

func products() []product {
	return []product{{
		ID:    0,
		Title: "The Comedy of Errors",
		DescriptionHTML: `<a href="https://en.wikipedia.org/wiki/The_Comedy_of_Errors">Wikipedia Summary</a>: ` +
			`The Comedy of Errors is one of <b>William Shakespeare's</b> early plays. It is his shortest and ` +
			`one of his most farcical comedies, with a major part of the humour coming from slapstick and ` +
			`mistaken identity, in addition to puns and word play.`,
	}}
}

// decodeDetails keeps the details payload untyped: the v1 and v2 details
// services report different value types for the same fields, and the template
// only ever prints them. Numbers are kept as json.Number so that they render
// exactly as the details service wrote them.
func decodeDetails(body []byte) map[string]any {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()

	var details map[string]any
	if err := decoder.Decode(&details); err != nil {
		log.Printf("decoding details response: %v", err)
		return nil
	}
	return details
}

// productPageView is everything productpage.html renders.
type productPageView struct {
	DetailsStatus int
	ReviewsStatus int
	Product       product
	Details       map[string]any
	Reviews       reviewsView
	User          string
}

type reviewsView struct {
	PodName     string       `json:"podname"`
	ClusterName string       `json:"clustername"`
	Reviews     []reviewView `json:"reviews"`
	Error       string       `json:"error"`
}

type reviewView struct {
	Reviewer string      `json:"reviewer"`
	Text     string      `json:"text"`
	Rating   *ratingView `json:"rating"`
}

type ratingView struct {
	Stars int    `json:"stars"`
	Color string `json:"color"`
	Error string `json:"error"`
}

// MissingStars is the number of hollow stars to draw after the filled ones.
func (r ratingView) MissingStars() int {
	return max(5-r.Stars, 0)
}

func decodeReviews(body []byte) reviewsView {
	var reviews reviewsView
	if err := json.Unmarshal(body, &reviews); err != nil {
		log.Printf("decoding reviews response: %v", err)
	}
	return reviews
}

// serviceTable renders the call graph shown on the landing page. The markup
// reproduces what json2html produced for the reference implementation,
// including the quirk that the root node is labelled with the details URL.
func serviceTable(detailsURL, reviewsURL, ratingsURL string) template.HTML {
	const attributes = `class="table table-condensed table-bordered table-hover"`

	//nolint:gosec // Every interpolated value is escaped just above.
	return template.HTML(fmt.Sprintf(
		`<table %[1]s>`+
			`<tr><th>name</th><td>%[2]s</td></tr>`+
			`<tr><th>endpoint</th><td>details</td></tr>`+
			`<tr><th>children</th><td>`+
			`<table %[1]s><thead><tr><th>name</th><th>endpoint</th><th>children</th></tr></thead><tbody>`+
			`<tr><td>%[2]s</td><td>details</td><td></td></tr>`+
			`<tr><td>%[3]s</td><td>reviews</td><td>`+
			`<table %[1]s><thead><tr><th>name</th><th>endpoint</th><th>children</th></tr></thead><tbody>`+
			`<tr><td>%[4]s</td><td>ratings</td><td></td></tr>`+
			`</tbody></table>`+
			`</td></tr>`+
			`</tbody></table>`+
			`</td></tr>`+
			`</table>`,
		attributes,
		template.HTMLEscapeString(detailsURL),
		template.HTMLEscapeString(reviewsURL),
		template.HTMLEscapeString(ratingsURL),
	))
}
