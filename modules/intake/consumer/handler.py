"""Placeholder for the SQS intake consumer (platform#8).

The real handler wraps the same path as `manage.py consume_intake`: for each SQS record,
create_incident_idempotent(...) (ADR-009 partial-unique dedupe) and, when newly created,
escalation.start_escalation(incident) to launch the per-incident Step Functions execution.
It django.setup() against RDS, so it's packaged with Django + deps by the pipeline (#10),
which updates this function's code. Until then this stub keeps the SQS event-source mapping
and wiring valid without bundling the app.
"""


def handler(event, context=None):
    raise RuntimeError(
        "intake consumer not yet deployed — the pipeline (#10) ships the real package"
    )
