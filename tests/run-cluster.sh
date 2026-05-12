#!/usr/bin/env bash
# tests/run-cluster.sh — Multi-container ("cluster") test.
# backend, redirector and client run in SEPARATE containers on a user-defined
# Docker network. The redirector is configured to proxy to http://backend:8080
# (DNS resolved by Docker), and curl is issued from the client container against
# the redirector container by name — exercising the real network path.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"
IMAGE="redirector-test:latest"
NET="redirector-net"

C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$C_C" "$C_0" "$*"; }
pass() { printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*"; FAILED=$((FAILED+1)); }

FAILED=0
TOTAL=0

BACKEND="cluster-backend"
CLIENT="cluster-client"
REDIRS=(
    cluster-redirector-apache2-catchall
    cluster-redirector-apache2-targeted
    cluster-redirector-nginx-catchall
    cluster-redirector-nginx-targeted
)

cleanup_all() {
    docker rm -f "$BACKEND" "$CLIENT" >/dev/null 2>&1 || true
    for c in "${REDIRS[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

curl_code() {
    local target="$1"; shift
    docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$target" 2>/dev/null || echo "ERR"
}

curl_body() {
    local target="$1"; shift
    docker exec "$CLIENT" curl -s --max-time 5 "$@" "$target" 2>/dev/null || true
}

assert_code() {
    local target="$1" expected="$2" desc="$3"; shift 3
    TOTAL=$((TOTAL+1))
    local code; code=$(curl_code "$target" "$@")
    if [[ "$code" == "$expected" ]]; then pass "$desc -> $code"
    else fail "$desc -> expected $expected, got $code"; fi
}

assert_body_contains() {
    local target="$1" needle="$2" desc="$3"; shift 3
    TOTAL=$((TOTAL+1))
    local body; body=$(curl_body "$target" "$@")
    if [[ "$body" == *"$needle"* ]]; then pass "$desc body contains '$needle'"
    else fail "$desc body missing '$needle' (got: $(printf '%.140s' "$body"))"; fi
}

# -- setup shared infra --
docker info >/dev/null 2>&1 || { echo "Docker unavailable" >&2; exit 1; }

info "Building image $IMAGE (if missing)..."
docker build -q -f "$TESTS/Dockerfile" -t "$IMAGE" "$TESTS" >/dev/null

info "Creating network $NET..."
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

info "Starting backend container..."
docker run -d --name "$BACKEND" --network "$NET" --network-alias backend "$IMAGE" >/dev/null
docker cp "$TESTS/backend.py" "$BACKEND":/backend.py
docker exec "$BACKEND" bash -c "sed -i 's/\r$//' /backend.py"
docker exec -d "$BACKEND" python3 /backend.py 8080 0.0.0.0
sleep 1

info "Starting client container..."
docker run -d --name "$CLIENT" --network "$NET" "$IMAGE" >/dev/null

# Sanity: client must reach backend directly.
TOTAL=$((TOTAL+1))
code=$(curl_code "http://backend:8080/probe")
if [[ "$code" == "200" ]]; then pass "client -> backend direct (sanity) -> 200"
else fail "client -> backend direct sanity (got $code)"; fi

run_redirector() {
    local ws="$1" mode="$2"
    local name="cluster-redirector-${ws}-${mode}"
    info "=== $ws / $mode (separate container, backend over docker DNS) ==="

    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$NET" --network-alias "$name" "$IMAGE" >/dev/null

    docker cp "$ROOT/redirector-setup.sh" "$name":/setup.sh
    docker exec "$name" bash -c "sed -i 's/\r$//' /setup.sh"

    local answers
    if [[ "$mode" == "catchall" ]]; then
        answers="${ws}
http://backend:8080
test.local
80
443
catchall
"
    else
        answers="${ws}
http://backend:8080
test.local
80
443
targeted
/api,/health
TestAgent
"
    fi

    local log="/tmp/cluster-${ws}-${mode}.log"
    if ! printf '%s' "$answers" | docker exec -i "$name" bash /setup.sh >"$log" 2>&1; then
        fail "setup script exited non-zero for $ws/$mode"
        sed -e 's/^/    | /' "$log"
        return
    fi
    sleep 1

    local base="http://${name}"
    local sbase="https://${name}"

    if [[ "$mode" == "catchall" ]]; then
        assert_code         "$base/"               200 "HTTP  /"
        assert_code         "$base/random"         200 "HTTP  /random"
        assert_body_contains "$base/random" "path=/random" "HTTP /random path"
        assert_body_contains "$base/random" "host=backend" "HTTP Host rewritten to backend"
        assert_code         "$base/api/deep/x"     200 "HTTP  /api/deep/x"
        assert_body_contains "$base/api/deep/x" "path=/api/deep/x" "HTTP /api/deep/x path"
        assert_code         "$sbase/random"        200 "HTTPS /random (-k)"      -k
        assert_body_contains "$sbase/random" "path=/random" "HTTPS /random path"  -k
        assert_body_contains "$sbase/random" "host=backend" "HTTPS Host rewritten to backend" -k
    else
        assert_code         "$base/api/x"          200 "HTTP  /api/x   UA=ok"   -H "User-Agent: TestAgent"
        assert_body_contains "$base/api/x" "path=/api/x" "HTTP /api/x path"     -H "User-Agent: TestAgent"
        assert_body_contains "$base/api/x" "host=backend" "HTTP Host rewritten to backend" -H "User-Agent: TestAgent"
        assert_code         "$base/health"         200 "HTTP  /health  UA=ok"   -H "User-Agent: TestAgent"
        assert_code         "$base/api"            200 "HTTP  /api     UA=ok"   -H "User-Agent: TestAgent"
        assert_code         "$base/api/x"          404 "HTTP  /api/x   UA=bad"  -H "User-Agent: Mozilla/5.0"
        assert_code         "$base/random"         404 "HTTP  /random  UA=ok"   -H "User-Agent: TestAgent"
        assert_code         "$base/apifoo"         404 "HTTP  /apifoo  UA=ok"   -H "User-Agent: TestAgent"
        assert_code         "$sbase/api/x"         200 "HTTPS /api/x   UA=ok"   -k -H "User-Agent: TestAgent"
        assert_body_contains "$sbase/api/x" "host=backend" "HTTPS Host rewritten to backend" -k -H "User-Agent: TestAgent"
        assert_code         "$sbase/random"        404 "HTTPS /random  UA=ok"   -k -H "User-Agent: TestAgent"
        assert_code         "$sbase/api/x"         404 "HTTPS /api/x   UA=bad"  -k -H "User-Agent: Mozilla/5.0"
    fi
}

run_redirector apache2 catchall
run_redirector apache2 targeted
run_redirector nginx   catchall
run_redirector nginx   targeted

printf '\n'
if ((FAILED == 0)); then
    printf '%sALL CLUSTER TESTS PASSED%s (%d/%d)\n' "$C_G" "$C_0" "$TOTAL" "$TOTAL"
    exit 0
else
    printf '%s%d/%d FAILED%s\n' "$C_R" "$FAILED" "$TOTAL" "$C_0"
    exit 1
fi
