.PHONY: test integration-test e2e-test build

test:
	nim c -r tests/test_guildy_error.nim

integration-test:
	@echo "no integration tests configured"

e2e-test:
	@echo "no e2e tests configured"

build:
	@echo "no build configured"
