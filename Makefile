.PHONY: test integration-test e2e-test build

NP := $(HOME)/.nimby/pkgs
NIM_PATHS := --path:"$(NP)/curly/src" --path:"$(NP)/jsony/src" --path:"$(NP)/webby/src" --path:"$(NP)/ws/src" --path:"$(NP)/libcurl" --path:"$(NP)/zippy/src" --path:"$(NP)/nimsimd/src" --path:"$(NP)/crunchy/src"

test:
	nim c $(NIM_PATHS) -r tests/test_guildy_error.nim
	nim c $(NIM_PATHS) -r tests/test_interaction_options.nim
	nim c $(NIM_PATHS) -r tests/test_mentions.nim
	nim c $(NIM_PATHS) -r tests/test_voice.nim
	nim c $(NIM_PATHS) -r tests/test_embed.nim
	nim c $(NIM_PATHS) -r tests/test_serialization.nim
	nim c $(NIM_PATHS) -r tests/test_verbose.nim

integration-test:
	@echo "no integration tests configured"

e2e-test:
	@echo "no e2e tests configured"

build:
	@echo "no build configured"
