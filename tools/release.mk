#-----------------------------------------------------------------------------
# Target: release management
#-----------------------------------------------------------------------------

# RELEASE_VERSION can be specified as "1.29" or "release-1.29"
# Examples:
#   make release.cherry-pick-list RELEASE_VERSION=1.29
#   make release.cherry-pick-list RELEASE_VERSION=release-1.29
#
# The script processes three types of commits:
#   1. isPermanent: true - Always cherry-picked to new releases (permanent downstream changes)
#   2. isPendingUpstreamSync: true - Cherry-picked only if not yet synced from upstream
#   3. isPermanent: false - Never cherry-picked (temporary changes)
#
# Output files:
#   - cherry-pick-to-release-X.Y.sh: Executable script for applying cherry-picks
#   - label-removal-report-X.Y.txt: Report of PRs needing label updates (if applicable)
.PHONY: release.cherry-pick-list
release.cherry-pick-list:
ifndef RELEASE_VERSION
	@echo "Error: RELEASE_VERSION must be specified on command line"
	@echo ""
	@echo "Usage:"
	@echo "  make release.cherry-pick-list RELEASE_VERSION=<version>"
	@echo ""
	@echo "Examples:"
	@echo "  make release.cherry-pick-list RELEASE_VERSION=1.29"
	@echo "  make release.cherry-pick-list RELEASE_VERSION=release-1.29"
	@exit 1
endif
	@bin/generate_cherrypick_list.sh $(RELEASE_VERSION)

.PHONY: release.help
release.help:
	@echo "Release Management Targets:"
	@echo "  release.cherry-pick-list RELEASE_VERSION=<version>"
	@echo "    Generate list of commits to cherry-pick for new release"
	@echo "    RELEASE_VERSION: Target release version (e.g., 1.29 or release-1.29)"
	@echo ""
	@echo "    Processes permanent downstream changes and pending-upstream-sync commits."
	@echo "    Checks which pending commits already exist in target branch."
	@echo "    Generates cherry-pick script and label removal report."
	@echo ""
	@echo "Example:"
	@echo "  make release.cherry-pick-list RELEASE_VERSION=1.29"
