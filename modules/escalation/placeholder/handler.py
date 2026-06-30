"""Placeholder for the escalation Lambdas (record_token / commit).

The real handlers (escalation/lambdas/*.py in the watch repo) django.setup() and call
incidents.services; they're packaged with Django + deps by the pipeline (#10), which
updates this function's code. Until then this stub keeps the function (and the Step
Functions wiring) valid without bundling the app. It must never run in a real execution.
"""


def handler(event, context=None):  # record_token.handler / commit.handler shape
    raise RuntimeError(
        "escalation Lambda not yet deployed — the pipeline (#10) ships the real package"
    )
