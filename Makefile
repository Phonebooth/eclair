.PHONY: all
all:
	@(rebar3 compile)

.PHONY: build
build: all
	mkdir -p .eclair/deps/base16/ebin
	mkdir -p .eclair/deps/eini/ebin
	mkdir -p .eclair/deps/envy/ebin
	mkdir -p .eclair/deps/erlcloud/ebin
	mkdir -p .eclair/deps/jsx/ebin
	mkdir -p .eclair/deps/lhttpc/ebin
	mkdir -p .eclair/deps/mini_s3/ebin
	cp _build/default/lib/base16/ebin/* .eclair/deps/base16/ebin
	cp _build/default/lib/eini/ebin/* .eclair/deps/eini/ebin
	cp _build/default/lib/envy/ebin/* .eclair/deps/envy/ebin
	cp _build/default/lib/erlcloud/ebin/* .eclair/deps/erlcloud/ebin
	cp _build/default/lib/jsx/ebin/* .eclair/deps/jsx/ebin
	cp _build/default/lib/lhttpc/ebin/* .eclair/deps/lhttpc/ebin
	cp _build/default/lib/mini_s3/ebin/* .eclair/deps/mini_s3/ebin
	tar cf eclair.tar -X build.exclude .eclair eclair.erl
