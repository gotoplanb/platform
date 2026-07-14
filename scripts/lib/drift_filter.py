#!/usr/bin/env python3
"""Report MEANINGFUL state-vs-reality drift from a refresh-only plan (ADR-046).

Reads `tofu show -json <refresh-only plan>` on stdin; prints one line per genuinely drifted
attribute. Silent when the only "drift" is the AWS provider normalising empty defaults.

Why this is not a grep. OpenTofu says "# aws_budgets_budget.this has changed" every single run,
because refreshing turns `metrics = null` into `metrics = []` and `tags = null` into `tags = {}`.
Those are the API answering with empty collections, not a human editing anything. A text-matching
drift report fires on them nightly, and a report that is never clean is a report nobody reads —
so it must be able to tell "null became empty" from "someone changed this".

The distinction we draw:
    before=None  ->  after=[] / {} / ""     provider normalisation. Ignore.
    before={"a": "b"}  ->  after={}         someone REMOVED the tags. Report.
    before="x"  ->  after="y"               someone changed it. Report.
"""
import json
import sys

EMPTY = ([], {}, "")

# Legacy COMPUTED attributes on aws_iam_role. When a role's policies are managed as separate
# resources — aws_iam_role_policy / aws_iam_role_policy_attachment, which is how this repo does it —
# these two mirror what the API reports and drift on every single refresh, in every stack, forever.
# They describe policies we already manage explicitly; they are not a channel anyone edits by hand.
IGNORE_ATTRS = {"managed_policy_arns", "inline_policy"}


def blank(value):
    return value is None or value in EMPTY


def differs(before, after):
    """True only if the API's value is a CHANGE, not a value state never tracked.

    The rule, and it holds at any depth: if state holds nothing and the API returns something, the
    attribute is computed — nobody edited it, terraform simply doesn't track it. That is `tags: null
    -> {}` on a budget, and it is equally `url: "" -> "https://api.github.com/..."` nested inside a
    GitHub label. Both fire on every refresh, forever, and neither is drift.

    A value state DOES hold, changing to something else, is drift — including a value being emptied
    (someone deleted the tags), which is why this is not symmetric.
    """
    if blank(before) and blank(after):
        return False  # null -> [] / {} — the API spelling "nothing" differently. Not a change.
    if isinstance(before, dict) and isinstance(after, dict):
        for k in set(before) | set(after):
            # Present in state but empty, filled in by AWS = a computed placeholder (a label's
            # `url`). ABSENT from state and present in AWS = someone ADDED it — which is the whole
            # point of this report, so the difference between "absent" and "empty" carries it.
            if k in before and blank(before[k]) and not blank(after.get(k)):
                continue
            if differs(before.get(k), after.get(k)):
                return True
        return False
    if isinstance(before, list) and isinstance(after, list):
        # AWS returns sets (tags, labels, policies) in arbitrary order; a reshuffle is not a change.
        # Pair by name when the elements are named blocks, else compare canonically by position.
        if all(isinstance(x, dict) and "name" in x for x in before + after):
            by_name_b = {x["name"]: x for x in before}
            by_name_a = {x["name"]: x for x in after}
            return any(
                differs(by_name_b.get(n), by_name_a.get(n))
                for n in set(by_name_b) | set(by_name_a)
            )
        key = lambda v: json.dumps(v, sort_keys=True, default=str)  # noqa: E731
        return sorted(before, key=key) != sorted(after, key=key)
    return before != after


def changed_attrs(before, after):
    """Attributes that genuinely differ, ignoring computed values and list reordering."""
    before = before or {}
    after = after or {}
    return [
        (key, before.get(key), after.get(key))
        for key in sorted(set(before) | set(after))
        if key not in IGNORE_ATTRS and differs(before.get(key), after.get(key))
    ]


def brief(value, limit=60):
    text = json.dumps(value, default=str) if not isinstance(value, str) else value
    return text if len(text) <= limit else text[: limit - 1] + "…"


def main():
    try:
        plan = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return

    for drift in plan.get("resource_drift", []):
        change = drift.get("change", {})
        actions = change.get("actions", [])

        address = drift.get("address", "?")
        if "delete" in actions:  # in state, gone from AWS — always worth saying
            print(f"  {address}: DELETED out from under state")
            continue

        attrs = changed_attrs(change.get("before"), change.get("after"))
        if not attrs:
            continue  # only normalisation — this is what the grep version got wrong
        for key, b, a in attrs:
            print(f"  {address}: {key}: {brief(b)} → {brief(a)}")


if __name__ == "__main__":
    main()
