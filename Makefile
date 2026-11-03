SHELL := /bin/sh

BUILD_ROOT ?= /pool/build/$(shell id -un)
SCX_LOADER_DIR ?= $(abspath ../scx-loader)
DPKG_BUILDPACKAGE ?= /usr/bin/dpkg-buildpackage
NATIVE ?= 1
BPF_CLANG ?= clang-22
BPF_RUST_TOOLCHAIN ?= nightly
LLVM_BIN ?= /usr/lib/llvm-22/bin
PREPARE_RUST_BPF ?= 1
CARGO_BUILD_JOBS ?= 2

export NATIVE BPF_CLANG CARGO_BUILD_JOBS
ifneq ($(strip $(BPF_RUST_TOOLCHAIN)),)
export BPF_RUST_TOOLCHAIN
endif
ifneq ($(strip $(LLVM_BIN)),)
export LLVM_BIN
endif
export PREPARE_RUST_BPF

.PHONY: build build-scx build-loader help

help:
	@printf '%s\n' \
		'build        build Debian source and binary packages for scx and scx-loader' \
		'build-scx    build the scx Debian source and binary packages' \
		'build-loader build the scx-loader Debian source and binary packages' \
		'NATIVE=0     disable -C target-cpu=native for cross-builds' \
		'BPF_CLANG=... select the BPF clang executable (default clang-22)' \
		'BPF_RUST_TOOLCHAIN=... select the rustup BPF toolchain (default nightly)' \
		'PREPARE_RUST_BPF=0 skip rust-src and bpf-linker preparation' \
		'CARGO_BUILD_JOBS=... cap Cargo parallelism (default 2)'

build: build-scx build-loader

build-scx:
	@bash scripts/release/build-deb.sh \
		--build-root "$(BUILD_ROOT)/scx" \
		--dpkg-buildpackage "$(DPKG_BUILDPACKAGE)"

build-loader:
	@test -d "$(SCX_LOADER_DIR)" || { \
		echo "scx-loader checkout not found: $(SCX_LOADER_DIR)" >&2; \
		exit 1; \
	}
	@$(MAKE) -C "$(SCX_LOADER_DIR)" build \
		BUILD_ROOT="$(BUILD_ROOT)" \
		DPKG_BUILDPACKAGE="$(DPKG_BUILDPACKAGE)"
