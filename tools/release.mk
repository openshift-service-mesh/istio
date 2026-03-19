#-----------------------------------------------------------------------------
# Target: release management
#-----------------------------------------------------------------------------

# RELEASE_VERSION can be specified as "1.29" or "release-1.29"
# Examples:
#   make release.cherry-pick-list RELEASE_VERSION=1.29
#   make release.cherry-pick-list RELEASE_VERSION=release-1.29
.PHONY: release.cherry-pick-list
release.cherry-pick-list:
	@bin/generate_cherrypick_list.sh $(RELEASE_VERSION)

.PHONY: release.help
release.help:
	@echo "Release Management Targets:"
	@echo "  release.cherry-pick-list RELEASE_VERSION=<version>"
	@echo "    Generate list of commits to cherry-pick for new release"
	@echo "    RELEASE_VERSION: Target release version (e.g., 1.29 or release-1.29)"
	@echo ""
	@echo "Example:"
	@echo "  make release.cherry-pick-list RELEASE_VERSION=1.29"
