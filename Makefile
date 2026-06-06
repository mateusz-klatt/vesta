.PHONY: setup build test coverage clean pull-spec

SIMULATOR ?= iPhone 17 Pro
DESTINATION = platform=iOS Simulator,name=$(SIMULATOR)
XCB = xcodebuild -project Vesta.xcodeproj -scheme Vesta -destination '$(DESTINATION)' -skipPackagePluginValidation

COVERAGE_RESULT_BUNDLE = build/test-results.xcresult
COVERAGE_REPORT = build/sonarqube-generic-coverage.xml

# hestia's emitted OpenAPI document (its repo checked out alongside this one).
HESTIA_SPEC ?= ../hestia/docs/api/openapi.json

setup:
	@command -v xcodegen >/dev/null 2>&1 || (echo "xcodegen not installed; run: brew install xcodegen" && exit 1)
	xcodegen generate

build: setup
	$(XCB) build

test: setup
	$(XCB) test

coverage: setup
	rm -rf $(COVERAGE_RESULT_BUNDLE)
	mkdir -p build
	$(XCB) -resultBundlePath $(COVERAGE_RESULT_BUNDLE) -enableCodeCoverage YES test
	scripts/xccov-to-sonarqube-generic.sh $(COVERAGE_RESULT_BUNDLE) > $(COVERAGE_REPORT)

# Re-pin the API contract from hestia and normalise it for swift-openapi-generator
# (pydantic emits Optional as anyOf-null, which the generator drops). The Swift
# types regenerate from this on the next build (it is a build plugin).
pull-spec:
	python3 scripts/normalize_openapi.py $(HESTIA_SPEC) Vesta/openapi.json
	@echo "Pinned + normalised $(HESTIA_SPEC) -> Vesta/openapi.json. Commit the diff."

clean:
	rm -rf build/ Vesta.xcodeproj/
