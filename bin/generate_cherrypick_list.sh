#!/bin/bash

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Generate list of commits to cherry-pick from previous release branch
# Usage: generate_cherrypick_list.sh <RELEASE_VERSION>
# Example: generate_cherrypick_list.sh 1.29
#          generate_cherrypick_list.sh release-1.29

set -e
set -u

# Create temp file for YAML content
YAML_TMP="$(mktemp)"
trap 'rm -f "${YAML_TMP}"' EXIT

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

function fail() {
  echo -e "${RED}ERROR: ${1}${NC}" >&2
  exit 1
}

function info() {
  echo -e "${BLUE}INFO: ${1}${NC}"
}

function warn() {
  echo -e "${YELLOW}WARNING: ${1}${NC}"
}

function success() {
  echo -e "${GREEN}SUCCESS: ${1}${NC}"
}

# Check dependencies
function check_dependencies() {
  if ! command -v yq &> /dev/null; then
    fail "yq is not installed. Please install yq v4.x from https://github.com/mikefarah/yq"
  fi

  if ! command -v curl &> /dev/null; then
    fail "curl is not installed. Please install curl."
  fi

  # Check yq version (v4.x required)
  local yq_version
  yq_version=$(yq --version | grep -oP 'version v\K[0-9]+' || echo "0")
  if [[ "$yq_version" -lt 4 ]]; then
    fail "yq version 4.x or higher is required. Current version: $(yq --version)"
  fi
}

# Parse and normalize version input
function parse_version() {
  local input="$1"

  # Remove "release-" prefix if present
  input="${input#release-}"

  # Validate format (MAJOR.MINOR)
  if [[ ! "$input" =~ ^[0-9]+\.[0-9]+$ ]]; then
    fail "Invalid version format: ${input}. Expected format: '1.29' or 'release-1.29'"
  fi

  echo "$input"
}

# Calculate previous release version (N-1)
function get_previous_version() {
  local current="$1"

  local major minor
  major=$(echo "$current" | cut -d'.' -f1)
  minor=$(echo "$current" | cut -d'.' -f2)

  # Decrement minor version
  local prev_minor=$((minor - 1))

  if [[ $prev_minor -lt 0 ]]; then
    fail "Cannot calculate previous version for ${current} (minor version cannot be negative)"
  fi

  echo "${major}.${prev_minor}"
}

# Fetch YAML file from GitHub
function fetch_yaml() {
  local branch="$1"
  local url="https://raw.githubusercontent.com/openshift-service-mesh/.github/main/downstream-changes/istio_${branch}.yaml"

  info "Fetching YAML from: ${url}"

  if ! curl -s -f -L "$url" -o "${YAML_TMP}"; then
    fail "Failed to fetch YAML file from ${url}\n  Possible reasons:\n  - File does not exist for branch '${branch}'\n  - Network connectivity issue\n  - GitHub API rate limit exceeded\n  Please check: https://github.com/openshift-service-mesh/.github/tree/main/downstream-changes"
  fi

  # Validate YAML structure
  if ! yq '.commits' "${YAML_TMP}" &> /dev/null; then
    fail "Invalid YAML structure: missing 'commits' field"
  fi
}

# Parse permanent commits from YAML
function parse_permanent_commits() {
  # Extract commits with isPermanent: true
  local commits
  commits=$(yq -r '.commits[] | select(.isPermanent == true) | "\(.sha)|\(.title)|\(.author)"' "${YAML_TMP}")

  if [[ -z "$commits" ]]; then
    warn "No permanent commits found in the YAML file"
    return 1
  fi

  echo "$commits"
}

# Parse pending-upstream-sync commits from YAML
function parse_pending_upstream_commits() {
  local commits
  commits=$(yq -r '.commits[] | select(.isPendingUpstreamSync == true) | "\(.sha)|\(.title)|\(.author)"' "${YAML_TMP}")

  # Just echo the result (empty string if no commits found)
  echo "$commits"
}

# Check if commit exists in target branch
# Returns: "FOUND" | "NOT_FOUND" | "COMMIT_MISSING"
function check_commit_in_branch() {
  local sha="$1"
  local branch="$2"

  # Step 1: Verify commit exists in local repository at all
  if ! git cat-file -e "${sha}" 2>/dev/null; then
    echo "COMMIT_MISSING"
    return
  fi

  # Step 2: Check if the local branch exists
  if ! git rev-parse --verify "${branch}" >/dev/null 2>&1; then
    # Branch doesn't exist locally - treat as not found
    echo "NOT_FOUND"
    return
  fi

  # Step 3: Check if commit is an ancestor of the local branch
  if git merge-base --is-ancestor "${sha}" "${branch}" 2>/dev/null; then
    echo "FOUND"
  else
    echo "NOT_FOUND"
  fi
}

# Process pending-upstream-sync commits
# Returns multi-line output with sections separated by ###SEPARATOR###
function process_pending_upstream_commits() {
  local pending_commits="$1"
  local target_branch="$2"

  local to_pick=""
  local already_synced=""

  # Handle empty input
  if [[ -z "$pending_commits" ]]; then
    echo ""
    echo "###SEPARATOR###"
    echo ""
    return
  fi

  while IFS='|' read -r sha title author; do
    # Skip empty lines
    if [[ -z "$sha" ]]; then
      continue
    fi

    info "Checking pending-upstream-sync commit: ${sha:0:8}..." >&2

    local status
    status=$(check_commit_in_branch "$sha" "$target_branch")

    case "$status" in
      "FOUND")
        # Commit found in branch - already synced from upstream
        already_synced="${already_synced}${sha}|${title}|${author}"$'\n'
        success "  Found in ${target_branch} - skipping (already synced)" >&2
        ;;
      "NOT_FOUND")
        # Commit not in branch - needs cherry-pick
        to_pick="${to_pick}${sha}|${title}|${author}"$'\n'
        warn "  Not found in ${target_branch} - adding to cherry-pick list" >&2
        ;;
      "COMMIT_MISSING")
        # Commit doesn't exist in repository - error case
        fail "  Commit ${sha} (${title}) not found in repository - manual investigation required"
        ;;
    esac
  done <<< "$pending_commits"

  # Remove trailing newlines
  to_pick="${to_pick%$'\n'}"
  already_synced="${already_synced%$'\n'}"

  # Output with separator on its own line
  echo "${to_pick}"
  echo "###SEPARATOR###"
  echo "${already_synced}"
}

# Generate report for commits that have synced from upstream
function generate_upstream_sync_report() {
  local synced_commits="$1"
  local current_version="$2"
  local report_name="upstream-sync-report-${current_version}.txt"

  if [[ -z "$synced_commits" ]]; then
    return 0
  fi

  # Generate report header
  cat > "$report_name" << EOF
Upstream Sync Report
Generated: $(date '+%Y-%m-%d %H:%M:%S')
Target release: release-${current_version}

The following commits were found in the target branch, indicating
successful upstream synchronization. These commits were automatically
skipped during cherry-pick list generation.

No action required - this report is for tracking and visibility only.
Labels can remain on PRs without any negative impact on future releases.

PR# | Commit SHA                               | Title
----+------------------------------------------+-------
EOF

  # Extract PR numbers and add to report
  while IFS='|' read -r sha title author; do
    local pr_number
    pr_number=$(git show "${sha}" --format="%s" -s 2>/dev/null | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || echo "???")
    printf "%-4s| %-40s | %s\n" "$pr_number" "$sha" "$title" >> "$report_name"
  done <<< "$synced_commits"

  echo "$report_name"
}

# Display commits in terminal
function display_commits() {
  local permanent_commits="$1"
  local pending_to_pick="$2"
  local pending_synced="$3"

  # Count commits
  local perm_count=0
  local pending_count=0
  local synced_count=0

  [[ -n "$permanent_commits" ]] && perm_count=$(echo "$permanent_commits" | wc -l)
  [[ -n "$pending_to_pick" ]] && pending_count=$(echo "$pending_to_pick" | wc -l)
  [[ -n "$pending_synced" ]] && synced_count=$(echo "$pending_synced" | wc -l)

  local total_to_pick=$((perm_count + pending_count))

  # Display summary
  echo ""
  echo "=========================================="
  echo "Cherry-Pick Summary"
  echo "=========================================="
  echo "Permanent downstream changes:          ${perm_count}"
  echo "Pending upstream sync (not in target): ${pending_count}"
  echo "Pending upstream sync (already synced): ${synced_count}"
  echo "------------------------------------------"
  echo "Total commits to cherry-pick:          ${total_to_pick}"
  echo "=========================================="
  echo ""

  # Display permanent commits section
  if [[ -n "$permanent_commits" ]]; then
    echo "PERMANENT DOWNSTREAM CHANGES:"
    echo "-----------------------------"
    printf "%-40s | %s\n" "SHA" "Title"
    printf "%s-+-%s\n" "----------------------------------------" "-----------------------------------------------------"
    while IFS='|' read -r sha title author; do
      printf "%-40s | %s\n" "$sha" "$title"
    done <<< "$permanent_commits"
    echo ""
  fi

  # Display pending commits to pick section
  if [[ -n "$pending_to_pick" ]]; then
    echo "PENDING UPSTREAM SYNC (needs cherry-pick):"
    echo "------------------------------------------"
    printf "%-40s | %s\n" "SHA" "Title"
    printf "%s-+-%s\n" "----------------------------------------" "-----------------------------------------------------"
    while IFS='|' read -r sha title author; do
      printf "%-40s | %s\n" "$sha" "$title"
    done <<< "$pending_to_pick"
    echo ""
  fi

  # Display already-synced commits section
  if [[ -n "$pending_synced" ]]; then
    echo "PENDING UPSTREAM SYNC (already in target branch):"
    echo "-------------------------------------------------"
    printf "%-40s | %s\n" "SHA" "Title"
    printf "%s-+-%s\n" "----------------------------------------" "-----------------------------------------------------"
    while IFS='|' read -r sha title author; do
      printf "%-40s | %s (✓ synced)\n" "$sha" "$title"
    done <<< "$pending_synced"
    echo ""
    info "These commits synced from upstream successfully."
    info "See upstream sync report for details."
    echo ""
  fi
}

# Generate cherry-pick script
function generate_script() {
  local permanent_commits="$1"
  local pending_commits="$2"
  local current_version="$3"
  local previous_version="$4"
  local script_name="cherry-pick-to-release-${current_version}.sh"

  cat > "$script_name" << EOF
#!/bin/bash

# Auto-generated cherry-pick script
# Generated by: make release.cherry-pick-list
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Target release: release-${current_version}
# Source: openshift-service-mesh/.github/downstream-changes/istio_release-${previous_version}.yaml

set -e

echo "Cherry-picking commits to release-${current_version}..."
echo ""

EOF

  # Add permanent commits section
  if [[ -n "$permanent_commits" ]]; then
    {
      echo "# ============================================"
      echo "# PERMANENT DOWNSTREAM CHANGES"
      echo "# ============================================"
      echo ""
      while IFS='|' read -r sha title author; do
        echo "# ${title}"
        echo "# Author: ${author}"
        echo "# Type: Permanent downstream change"
        echo "git cherry-pick ${sha}"
        echo ""
      done <<< "$permanent_commits"
    } >> "$script_name"
  fi

  # Add pending-upstream commits section
  if [[ -n "$pending_commits" ]]; then
    {
      echo "# ============================================"
      echo "# PENDING UPSTREAM SYNC"
      echo "# These commits are awaiting upstream sync"
      echo "# ============================================"
      echo ""
      while IFS='|' read -r sha title author; do
        echo "# ${title}"
        echo "# Author: ${author}"
        echo "# Type: Pending upstream synchronization"
        echo "git cherry-pick ${sha}"
        echo ""
      done <<< "$pending_commits"
    } >> "$script_name"
  fi

  echo "echo \"All commits cherry-picked successfully!\"" >> "$script_name"

  chmod +x "$script_name"

  echo "$script_name"
}

# Main function
function main() {
  local release_version="$1"

  info "Starting cherry-pick list generation..."
  echo ""

  # Check dependencies
  check_dependencies

  # Parse version
  local normalized_version
  normalized_version=$(parse_version "$release_version")
  info "Target release version: release-${normalized_version}"

  # Calculate previous version
  local previous_version
  previous_version=$(get_previous_version "$normalized_version")
  info "Previous release version: release-${previous_version}"
  echo ""

  # Fetch YAML
  fetch_yaml "release-${previous_version}"
  success "YAML file fetched successfully"
  echo ""

  # Parse permanent commits (existing)
  local permanent_commits=""
  if commits=$(parse_permanent_commits); then
    permanent_commits="$commits"
  fi

  # Parse pending-upstream commits (NEW)
  local pending_to_pick=""
  local pending_synced=""
  local pending
  pending=$(parse_pending_upstream_commits)

  if [[ -n "$pending" ]]; then
    info "Processing pending-upstream-sync commits against target branch..."
    echo ""

    local result
    result=$(process_pending_upstream_commits "$pending" "release-${normalized_version}")

    # Split on separator line
    pending_to_pick=$(echo "$result" | sed -n '1,/^###SEPARATOR###$/p' | grep -v "^###SEPARATOR###$" || true)
    pending_synced=$(echo "$result" | sed -n '/^###SEPARATOR###$/,$p' | grep -v "^###SEPARATOR###$" || true)

    echo ""
  fi

  # Check if we have any commits to cherry-pick
  if [[ -z "$permanent_commits" ]] && [[ -z "$pending_to_pick" ]]; then
    warn "No commits to cherry-pick found"

    # Still generate report if there are synced commits
    if [[ -n "$pending_synced" ]]; then
      display_commits "" "" "$pending_synced"
      local report_name
      report_name=$(generate_upstream_sync_report "$pending_synced" "$normalized_version")
      info "Upstream sync report generated: ${report_name}"
    fi

    exit 0
  fi

  # Display commits
  display_commits "$permanent_commits" "$pending_to_pick" "$pending_synced"

  # Generate cherry-pick script
  local script_name
  script_name=$(generate_script "$permanent_commits" "$pending_to_pick" "$normalized_version" "$previous_version")

  success "Cherry-pick script generated: ${script_name}"
  echo ""

  # Generate upstream sync report if needed
  if [[ -n "$pending_synced" ]]; then
    local report_name
    report_name=$(generate_upstream_sync_report "$pending_synced" "$normalized_version")
    success "Upstream sync report generated: ${report_name}"
    echo ""
  fi

  echo "To apply these commits, run:"
  echo "  ./${script_name}"
  echo ""
  echo "Or cherry-pick manually using the list above."
}

# Entry point
if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <RELEASE_VERSION>"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") 1.29"
  echo "  $(basename "$0") release-1.29"
  exit 1
fi

main "$1"
