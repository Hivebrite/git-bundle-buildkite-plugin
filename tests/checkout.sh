#!/bin/bash
# Runs hooks/checkout against a local repo with a stubbed gcloud. No network.
# Usage: tests/checkout.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

BIN="${TMP}/bin"
mkdir -p "${BIN}"
if ! command -v timeout >/dev/null 2>&1; then
  ln -s "$(command -v gtimeout)" "${BIN}/timeout"
fi

git init -q "${TMP}/origin"
git -C "${TMP}/origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "${TMP}/origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
COMMIT="$(git -C "${TMP}/origin" rev-parse HEAD)"

git clone -q --depth=1 "file://${TMP}/origin" "${TMP}/seed"
tar -cf "${TMP}/cache.tar" -C "${TMP}/seed" .

cat >"${BIN}/gcloud" <<EOF
#!/bin/bash
case "\${GCLOUD_MODE:-ok}" in
  ok) cp "${TMP}/cache.tar" "\$4" ;;
  hang) exec sleep 600 ;;
  hang-once)
    if [ ! -e "${TMP}/hung" ]; then : >"${TMP}/hung"; exec sleep 600; fi
    cp "${TMP}/cache.tar" "\$4" ;;
  missing) echo "NotFound: 404" >&2; exit 1 ;;
esac
EOF
chmod +x "${BIN}/gcloud"

failures=0

run_hook() {
  local mode=$1
  rm -rf "${TMP}/co" "${TMP}/hung"
  GCLOUD_MODE="${mode}" PATH="${BIN}:${PATH}" \
    BUILDKITE_PLUGIN_GIT_BUNDLE_GCS_URI="gs://bucket/cache.tar" \
    BUILDKITE_PLUGIN_GIT_BUNDLE_DOWNLOAD_TIMEOUT=2 \
    BUILDKITE_PLUGIN_GIT_BUNDLE_GIT_TIMEOUT=5 \
    BUILDKITE_BUILD_CHECKOUT_PATH="${TMP}/co" \
    BUILDKITE_REPO="file://${TMP}/origin" \
    BUILDKITE_COMMIT="${COMMIT}" \
    BUILDKITE_GIT_CLONE_FLAGS="-v --depth=1" \
    BUILDKITE_GIT_FETCH_FLAGS="-v --depth=1" \
    bash "${ROOT}/hooks/checkout" >"${TMP}/out" 2>&1
}

expect() {
  local name=$1 want_rc=$2 want_head=$3 want_log=$4 rc=0 start=${SECONDS}
  run_hook "${name%%:*}" || rc=$?
  local head=""
  if [ -d "${TMP}/co/.git" ]; then head="$(git -C "${TMP}/co" rev-parse HEAD)"; fi
  if [ "${rc}" -eq "${want_rc}" ] && [ "${head}" = "${want_head}" ] && grep -q "${want_log}" "${TMP}/out"; then
    echo "ok   ${name} (exit ${rc}, $((SECONDS - start))s)"
  else
    echo "FAIL ${name}: exit ${rc} (want ${want_rc}), head '${head}'"
    cat "${TMP}/out"
    failures=$((failures + 1))
  fi
}

expect "ok:seeds from the cache" 0 "${COMMIT}" "SEEDED from GCS cache"
expect "hang-once:retries a hung download" 0 "${COMMIT}" "download: TIMED OUT"
expect "missing:falls back to a normal checkout" 0 "${COMMIT}" "cache unavailable; normal checkout"
expect "hang:exits 128 after two hung downloads" 128 "" "download: hung twice, exiting 128"

[ "${failures}" -eq 0 ]
