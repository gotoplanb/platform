"""HTTP API request authorizer for the intake webhook (platform#8, ADR-002/008).

Validates the machine-to-machine shared secret (header X-Watch-Webhook-Secret) against
the SSM SecureString (#5) before API Gateway forwards the body to SQS. Self-contained
(boto3 + SSM only) — no Django, no DB — so the ingest path stays independent of the app
tier. The secret is fetched once and cached for the execution environment's lifetime.
"""
import hmac
import os

import boto3

_expected = None


def _expected_secret():
    global _expected
    if _expected is None:
        resp = boto3.client("ssm").get_parameter(
            Name=os.environ["WEBHOOK_SECRET_PARAM_NAME"], WithDecryption=True
        )
        _expected = resp["Parameter"]["Value"]
    return _expected


def handler(event, context=None):
    # HTTP API lower-cases header names; identity source guarantees presence.
    provided = (event.get("headers") or {}).get("x-watch-webhook-secret", "")
    authorized = bool(provided) and hmac.compare_digest(provided, _expected_secret())
    return {"isAuthorized": authorized}
