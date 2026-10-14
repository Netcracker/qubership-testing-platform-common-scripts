#!/usr/bin/env bash
# b3_trace.sh — B3-style trace/span id generation shared by test runners.
#
# Header contract (see runner READMEs for the authoritative description):
#   X-B3-TraceId: <PROJECT_ID><RUN_ID><testcase_id>   — 13 chars, fixed for one test case
#   X-B3-SpanId:  <16 hex chars>                        — fresh for every step
#   X-B3-Sampled: 1                                     — always
#
# PROJECT_ID and RUN_ID are supplied by the orchestrator and used as-is: this
# module does not pad, truncate, or hash them.

# ---------------------------------------------------------------------------
# _b3_random_hex COUNT
#
# Prints COUNT lowercase hex characters read from the kernel RNG.
#
# Args:
#   $1  count — number of hex characters to return (must be <= 32)
# ---------------------------------------------------------------------------
_b3_random_hex() {
  local count="$1"
  local uuid
  uuid=$(tr -d '-' < /proc/sys/kernel/random/uuid)
  printf '%s' "${uuid:0:count}"
}

# ---------------------------------------------------------------------------
# generate_b3_testcase_id
#
# Prints a fresh 5-character hex id identifying one test case, used as the
# last segment of X-B3-TraceId.
# ---------------------------------------------------------------------------
generate_b3_testcase_id() {
  _b3_random_hex 5
}

# ---------------------------------------------------------------------------
# generate_b3_span_id
#
# Prints a fresh 16-character hex id for X-B3-SpanId (one per step).
# ---------------------------------------------------------------------------
generate_b3_span_id() {
  _b3_random_hex 16
}

# ---------------------------------------------------------------------------
# compose_b3_trace_id
#
# Prints "<PROJECT_ID><RUN_ID><testcase_id>" for use as X-B3-TraceId, or
# nothing (with a warning on stderr) when PROJECT_ID/RUN_ID are not set.
#
# Globals read: PROJECT_ID, RUN_ID
# ---------------------------------------------------------------------------
compose_b3_trace_id() {
  if [ -z "${PROJECT_ID:-}" ] || [ -z "${RUN_ID:-}" ]; then
    echo "⚠️ PROJECT_ID/RUN_ID not set — skipping B3 trace id generation" >&2
    return 0
  fi

  printf '%s%s%s' "$PROJECT_ID" "$RUN_ID" "$(generate_b3_testcase_id)"
}
