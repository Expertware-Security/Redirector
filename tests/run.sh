#!/usr/bin/env bash
# tests/run.sh — Exercise redirector-setup.sh across the 4 supported
# combinations: {apache2, nginx} x {catchall, targeted}.
#
# Each combination spins up a fresh container, copies the script + backend in,
# starts the backend on 127.0.0.1:8080, drives the setup script via piped
# answers, then curls a battery of assertions against the redirector.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"
IMAGE="redirector-test:latest"

C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$C_C" "$C_0" "$*"; }
note() { printf '%s[i]%s %s\n' "$C_Y" "$C_0" "$*"; }
pass() { printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*"; FAILED=$((FAILED+1)); }

FAILED=0
TOTAL=0

CONTAINERS=(
    redirector-test-apache2-catchall
    redirector-test-apache2-targeted
    redirector-test-nginx-catchall
    redirector-test-nginx-targeted
)

cleanup_all() {
    for c in "${CONTAINERS[@]}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
}
trap cleanup_all EXIT

build_image() {
    info "Building image $IMAGE (one-time, ~30s)..."
    docker build -q -f "$TESTS/Dockerfile" -t "$IMAGE" "$TESTS" >/dev/null
}

curl_code() {
    local container="$1"; shift
    docker exec "$container" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo "ERR"
}

curl_body() {
    local container="$1"; shift
    docker exec "$container" curl -s --max-time 5 "$@" 2>/dev/null || true
}

assert_code() {
    local container="$1" expected="$2" desc="$3"; shift 3
    TOTAL=$((TOTAL+1))
    local code; code=$(curl_code "$container" "$@")
    if [[ "$code" == "$expected" ]]; then
        pass "$desc -> $code"
    else
        fail "$desc -> expected $expected, got $code"
    fi
}

assert_body_contains() {
    local container="$1" needle="$2" desc="$3"; shift 3
    TOTAL=$((TOTAL+1))
    local body; body=$(curl_body "$container" "$@")
    if [[ "$body" == *"$needle"* ]]; then
        pass "$desc body contains '$needle'"
    else
        fail "$desc body missing '$needle' (got: $(printf '%.120s' "$body"))"
    fi
}

run_test() {
    local ws="$1" mode="$2"
    local container="redirector-test-${ws}-${mode}"

    info "=== $ws / $mode ==="

    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name "$container" "$IMAGE" >/dev/null

    docker cp "$ROOT/redirector-setup.sh" "$container":/setup.sh
    docker cp "$TESTS/backend.py" "$container":/backend.py
    # Normalize line endings if the script was saved on Windows.
    docker exec "$container" bash -c "sed -i 's/\\r\$//' /setup.sh /backend.py"

    docker exec -d "$container" python3 /backend.py 8080
    sleep 1

    local answers
    if [[ "$mode" == "catchall" ]]; then
        answers="${ws}
http://127.0.0.1:8080
test.local
80
443
catchall
self-signed
"
    else
        answers="${ws}
http://127.0.0.1:8080
test.local
80
443
targeted
/api,/health
TestAgent
self-signed
"
    fi

    local log="/tmp/redir-${ws}-${mode}.log"
    if ! printf '%s' "$answers" | docker exec -i "$container" bash /setup.sh >"$log" 2>&1; then
        fail "setup script exited non-zero for $ws/$mode"
        sed -e 's/^/    | /' "$log"
        return
    fi

    sleep 1

    # ACME HTTP-01 passthrough must work in every mode (so Let's Encrypt
    # issuance is possible even when targeted mode would 404 /unknown paths).
    docker exec "$container" bash -c 'mkdir -p /var/www/html/.well-known/acme-challenge && printf acme-ok > /var/www/html/.well-known/acme-challenge/token123'
    assert_code         "$container" 200 "ACME challenge served locally"            "http://127.0.0.1/.well-known/acme-challenge/token123"
    assert_body_contains "$container" "acme-ok" "ACME challenge body"               "http://127.0.0.1/.well-known/acme-challenge/token123"

    if [[ "$mode" == "catchall" ]]; then
        assert_code         "$container" 200 "HTTP  /"               "http://127.0.0.1/"
        assert_code         "$container" 200 "HTTP  /random"         "http://127.0.0.1/random"
        assert_body_contains "$container" "path=/random" "HTTP /random preserves path" "http://127.0.0.1/random"
        assert_code         "$container" 200 "HTTP  /api/deep/x"     "http://127.0.0.1/api/deep/x"
        assert_body_contains "$container" "path=/api/deep/x" "HTTP /api/deep/x preserves path" "http://127.0.0.1/api/deep/x"
        assert_code         "$container" 200 "HTTPS /random   (-k)"  -k "https://127.0.0.1/random"
        assert_body_contains "$container" "path=/random" "HTTPS /random preserves path" -k "https://127.0.0.1/random"
    else
        assert_code         "$container" 200 "HTTP  /api/x      UA=ok " -H "User-Agent: TestAgent"   "http://127.0.0.1/api/x"
        assert_body_contains "$container" "path=/api/x" "HTTP /api/x preserves path" -H "User-Agent: TestAgent" "http://127.0.0.1/api/x"
        assert_code         "$container" 200 "HTTP  /health     UA=ok " -H "User-Agent: TestAgent"   "http://127.0.0.1/health"
        assert_code         "$container" 200 "HTTP  /api        UA=ok " -H "User-Agent: TestAgent"   "http://127.0.0.1/api"
        assert_code         "$container" 404 "HTTP  /api/x      UA=bad" -H "User-Agent: Mozilla/5.0" "http://127.0.0.1/api/x"
        assert_code         "$container" 404 "HTTP  /random     UA=ok " -H "User-Agent: TestAgent"   "http://127.0.0.1/random"
        assert_code         "$container" 404 "HTTP  /apifoo     UA=ok " -H "User-Agent: TestAgent"   "http://127.0.0.1/apifoo"
        assert_code         "$container" 200 "HTTPS /api/x      UA=ok " -k -H "User-Agent: TestAgent"   "https://127.0.0.1/api/x"
        assert_code         "$container" 404 "HTTPS /random     UA=ok " -k -H "User-Agent: TestAgent"   "https://127.0.0.1/random"
        assert_code         "$container" 404 "HTTPS /api/x      UA=bad" -k -H "User-Agent: Mozilla/5.0" "https://127.0.0.1/api/x"
    fi

    docker rm -f "$container" >/dev/null
}

if ! docker info >/dev/null 2>&1; then
    printf '%s[x]%s Docker is not available.\n' "$C_R" "$C_0" >&2
    exit 1
fi

build_image
run_test apache2 catchall
run_test apache2 targeted
run_test nginx   catchall
run_test nginx   targeted

printf '\n'
if ((FAILED == 0)); then
    printf '%sALL TESTS PASSED%s (%d/%d)\n' "$C_G" "$C_0" "$TOTAL" "$TOTAL"
    exit 0
else
    printf '%s%d/%d FAILED%s\n' "$C_R" "$FAILED" "$TOTAL" "$C_0"
    exit 1
fi
