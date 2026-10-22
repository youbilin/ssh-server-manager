#!/usr/bin/env bash
# shellcheck disable=SC2034
# Validate the shape of the eval fixtures (no model call).

. "$(dirname "$0")/lib.sh"

CURRENT_TEST="eval fixtures"
if command -v python3 >/dev/null 2>&1; then
  PYEXE=python3
elif command -v python >/dev/null 2>&1; then
  PYEXE=python
else
  echo "SKIP eval fixtures: Python not installed"
  summary "test_evals"
  exit 0
fi

"$PYEXE" - "$ROOT_DIR/evals/evals.json" "$ROOT_DIR/evals/trigger-evals.json" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    evals = json.load(fh)
assert evals.get("skill_name") == "ssh-server-manager"
assert isinstance(evals.get("evals"), list) and len(evals["evals"]) > 0
for item in evals["evals"]:
    for key in ("id", "prompt", "expected_output", "expectations"):
        assert key in item, (key, item)
    assert isinstance(item["expectations"], list) and item["expectations"]

with open(sys.argv[2], encoding="utf-8") as fh:
    triggers = json.load(fh)
assert isinstance(triggers, list) and len(triggers) > 0
for item in triggers:
    assert isinstance(item.get("query"), str) and item["query"]
    assert isinstance(item.get("should_trigger"), bool), item
PY
assert_rc 0 $? "eval fixture JSON shape"

summary "test_evals"
