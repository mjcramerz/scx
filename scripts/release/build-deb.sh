#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

die() {
    printf 'build-deb: %s\n' "$1" >&2
    exit 1
}

build_root=
dpkg_buildpackage=/usr/bin/dpkg-buildpackage
skip_dpkg_builddeps=0
: "${CARGO_BUILD_JOBS:=2}"
export CARGO_BUILD_JOBS

while (($#)); do
    case $1 in
        --build-root)
            (($# >= 2)) || die "--build-root requires a value"
            build_root=$2
            shift 2
            ;;
        --dpkg-buildpackage)
            (($# >= 2)) || die "--dpkg-buildpackage requires a value"
            dpkg_buildpackage=$2
            shift 2
            ;;
        --)
            shift
            (($# == 0)) || die "unexpected arguments after --"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n $build_root ]] || die "--build-root is required"
[[ $build_root == /* ]] || die "build root must be absolute"
[[ $build_root != / ]] || die "refusing to use / as the build root"
[[ $build_root != *$'\n'* ]] || die "build root contains a newline"
[[ -x $dpkg_buildpackage ]] || die "dpkg-buildpackage is not executable: $dpkg_buildpackage"

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
[[ -f $repo_root/debian/control ]] || die "missing debian/control"
[[ -f $repo_root/debian/rules ]] || die "missing debian/rules"
[[ -f $repo_root/debian/changelog ]] || die "missing debian/changelog"

for command in git tar dpkg-parsechangelog dpkg-checkbuilddeps python3 cargo; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
command -v rustc >/dev/null 2>&1 || die "required command not found: rustc"
command -v grep >/dev/null 2>&1 || die "required command not found: grep"

source_package=$(dpkg-parsechangelog -l "$repo_root/debian/changelog" -S Source)
debian_version=$(dpkg-parsechangelog -l "$repo_root/debian/changelog" -S Version)
upstream_version=${debian_version%-*}
[[ $source_package =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || die "invalid source package name"
[[ $upstream_version =~ ^[0-9][0-9A-Za-z.+:~]*$ ]] || die "invalid upstream version"

check_build_dependencies() {
    local output missing
    if output=$(dpkg-checkbuilddeps "$repo_root/debian/control" 2>&1); then
        return 0
    fi

    missing=${output#*unmet build dependencies: }
    if [[ $output == "dpkg-checkbuilddeps: error: unmet build dependencies: "* ]] \
        && [[ $missing == "cargo rustc" ]] \
        && cargo --version >/dev/null 2>&1 \
        && rustc --version >/dev/null 2>&1; then
        printf '%s\n' \
            'build-deb: warning: using executable cargo/rustc toolchain outside dpkg' \
            'build-deb: warning: Debian control dependencies remain unchanged for installed builds' >&2
        skip_dpkg_builddeps=1
        return 0
    fi

    printf '%s\n' "$output" >&2
    die "Debian build dependencies are not installed"
}

check_build_dependencies

prepare_rust_bpf_toolchain() {
    local toolchain=${BPF_RUST_TOOLCHAIN:-nightly}
    local installed_components
    [[ $toolchain != *$'\n'* ]] || die "BPF_RUST_TOOLCHAIN contains a newline"

    case ${PREPARE_RUST_BPF:-1} in
        0)
            return 0
            ;;
        1)
            ;;
        *)
            die "PREPARE_RUST_BPF must be 0 or 1"
            ;;
    esac

    if [[ -n ${LLVM_BIN:-} ]]; then
        [[ -d $LLVM_BIN ]] || die "LLVM_BIN is not a directory: $LLVM_BIN"
        PATH="$LLVM_BIN:$PATH"
        export PATH
    fi

    command -v rustup >/dev/null 2>&1 || die "required command not found: rustup"
    if ! installed_components=$(rustup component list --installed \
        --toolchain "$toolchain"); then
        die "could not query rustup toolchain $toolchain"
    fi
    if ! grep -q '^rust-src' <<<"$installed_components"; then
        printf 'build-deb: adding rust-src to rustup toolchain %s\n' "$toolchain" >&2
        rustup component add rust-src --toolchain "$toolchain"
    fi

    if ! command -v bpf-linker >/dev/null 2>&1; then
        if ! command -v cargo-binstall >/dev/null 2>&1; then
            printf '%s\n' \
                'build-deb: installing cargo-binstall with the locked manifest' >&2
            cargo install cargo-binstall --locked
        fi
        command -v cargo-binstall >/dev/null 2>&1 \
            || die "cargo-binstall was not installed on PATH"
        printf '%s\n' 'build-deb: installing bpf-linker with cargo binstall' >&2
        cargo binstall --no-confirm bpf-linker
    fi

    for command in bpf-linker llvm-objcopy llvm-nm; do
        command -v "$command" >/dev/null 2>&1 \
            || die "required Rust BPF tool not found: $command"
        "$command" --version >/dev/null 2>&1 \
            || die "required Rust BPF tool cannot execute: $command"
    done
}

vendor_rust_bpf_dependencies() {
    case ${PREPARE_RUST_BPF:-1} in
        0)
            return 0
            ;;
        1)
            ;;
        *)
            die "PREPARE_RUST_BPF must be 0 or 1"
            ;;
    esac

    local toolchain=${BPF_RUST_TOOLCHAIN:-nightly}
    local sysroot sysroot_vendor crate_dir crate_name copied=0
    if ! sysroot=$(rustup run "$toolchain" rustc --print sysroot); then
        die "could not locate rustup sysroot for toolchain $toolchain"
    fi
    [[ $sysroot != *$'\n'* ]] || die "rustup sysroot contains a newline"
    sysroot_vendor="$sysroot/lib/rustlib/src/rust/library/vendor"
    [[ -d $sysroot_vendor ]] || die "missing Rust sysroot vendor directory: $sysroot_vendor"

    for crate_dir in "$sysroot_vendor"/*; do
        [[ -d $crate_dir ]] || continue
        crate_name=${crate_dir##*/}
        if [[ ! -e vendor/$crate_name ]]; then
            cp -a -- "$crate_dir" "vendor/$crate_name"
            copied=$((copied + 1))
        fi
    done
    if ((copied)); then
        printf 'build-deb: added %d Rust sysroot vendor crates\n' "$copied" >&2
    fi
}

prepare_rust_bpf_toolchain

mkdir -p -- "$build_root"
build_root=$(CDPATH='' cd -- "$build_root" && pwd -P)
source_root="$build_root/${source_package}-${upstream_version}"
[[ $source_root == "$build_root/"* ]] || die "source root escaped build root"
[[ $source_root != "$build_root" ]] || die "invalid source root"
rm -rf -- "$source_root"

tmp_root=$(mktemp -d "$build_root/.${source_package}.XXXXXX")
cleanup() {
    if [[ -n ${tmp_root:-} ]]; then
        rm -rf -- "$tmp_root"
    fi
}
trap cleanup EXIT

git -C "$repo_root" archive --format=tar HEAD | tar -xf - -C "$tmp_root"
mv -- "$tmp_root" "$source_root"
tmp_root=

rm -rf -- "$source_root/debian"
cp -a -- "$repo_root/debian" "$source_root/debian"
mkdir -p -- "$source_root/.cargo"
(
    cd -- "$source_root"
    cargo vendor --locked >> .cargo/config.toml
    vendor_rust_bpf_dependencies
    python3 debian/sanitize-vendor-checksums.py
    python3 debian/update-vendor-copyright --source-root .
)

orig_tarball="$build_root/${source_package}_${upstream_version}.orig.tar.xz"
tar --create --xz --file "$orig_tarball" \
    --directory "$build_root" \
    --exclude="${source_package}-${upstream_version}/debian" \
    --sort=name --mtime='1970-01-01 00:00:00 UTC' \
    --owner=0 --group=0 --numeric-owner \
    "${source_package}-${upstream_version}"

printf 'building %s %s in %s\n' "$source_package" "$debian_version" "$build_root"
buildpackage_args=(--build=full --no-sign)
if ((skip_dpkg_builddeps)); then
    buildpackage_args+=(--no-check-builddeps)
fi
(
    cd -- "$source_root"
    exec "$dpkg_buildpackage" "${buildpackage_args[@]}"
)

printf 'artifacts: %s\n' "$build_root"
