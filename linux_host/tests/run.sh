#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR="$ROOT_DIR/linux_host/tests"
WORK_DIR="$TEST_DIR/.work"

pass_count=0
fail_count=0

if [ "$(id -u)" -ne 0 ]; then
    echo "linux_host tests must run as root" >&2
    exit 1
fi

install_deps() {
    local need=()
    command -v jq >/dev/null 2>&1 || need+=(jq)
    command -v useradd >/dev/null 2>&1 || need+=(passwd)
    command -v loginctl >/dev/null 2>&1 || need+=(systemd)
    command -v flock >/dev/null 2>&1 || need+=(util-linux)

    if ! command -v shellcheck >/dev/null 2>&1; then
        need+=(shellcheck)
    fi

    if [ "${#need[@]}" -gt 0 ] && command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends "${need[@]}" || true
    fi
}

# The host scripts, plus the bootstrap scripts the Custom Script Extension runs.
lint_targets() {
    find "$ROOT_DIR/linux_host" -type f -name '*.sh'
    if [ -d "$ROOT_DIR/custom_script_extensions" ]; then
        find "$ROOT_DIR/custom_script_extensions" -type f -name '*.sh'
    fi
}

syntax_check() {
    local file

    while IFS= read -r file; do
        bash -n "$file"
    done < <(lint_targets | sort)

    if command -v shellcheck >/dev/null 2>&1; then
        while IFS= read -r file; do
            shellcheck --severity=error "$file"
        done < <(lint_targets | sort)
    else
        echo "shellcheck not available; skipping optional lint"
    fi
}

run_tests() {
    local test_file name

    while IFS= read -r test_file; do
        name=$(basename "$test_file")
        echo "==> $name"
        if bash "$test_file"; then
            echo "PASS $name"
            pass_count=$((pass_count + 1))
        else
            echo "FAIL $name" >&2
            fail_count=$((fail_count + 1))
        fi
    done < <(find "$TEST_DIR" -maxdepth 1 -type f -name 'test_*.sh' | sort)
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
install_deps
syntax_check
run_tests

echo "Summary: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]