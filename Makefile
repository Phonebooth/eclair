PROJECT = eclair
DEPS = mini_s3
dep_mini_s3 = git git@github.com:Phonebooth/mini_s3.git master
include erlang.mk

build: all
	mkdir -p .eclair/deps/mini_s3/ebin
	mkdir -p .eclair/deps/ibrowse/ebin
	cp deps/mini_s3/ebin/* .eclair/deps/mini_s3/ebin
	cp deps/ibrowse/ebin/* .eclair/deps/ibrowse/ebin
	tar cf eclair.tar -X build.exclude .eclair eclair.erl
