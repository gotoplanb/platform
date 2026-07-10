#!/usr/bin/env python3
"""Tiny local "AWS access portal" — a zero-dependency stand-in for the IAM Identity Center
start page, so you don't have to hand-craft switch-role URLs to reach the member accounts.

It serves one local HTML page listing each account with one-click **switch-role** links (console)
per role. Account IDs are read from the same place the estate uses — the env vars named in the
config (your gitignored `.env`) — so no account IDs are committed to this public repo.

Config: `scripts/aws-portal.json` if present, else `scripts/aws-portal.example.json`. Copy the
example to customize labels/colors/roles:  cp scripts/aws-portal.example.json scripts/aws-portal.json

Usage:  python3 scripts/aws-portal.py [PORT]   (default 8765; binds 127.0.0.1 only)
        make portal [PORT=8765]

NOTE: switch-role links require you to already be signed into the **management** account as an IAM
user (root can't switch roles). The real fix for a work-style portal is AWS IAM Identity Center
(free, Terraformable) — this is the quick stand-in / offline fallback.
"""
import html
import json
import os
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent  # platform/


def load_dotenv(path: Path) -> dict:
    """Minimal KEY=VALUE parser for the repo .env (gitignored). Returns {} if absent."""
    env = {}
    if not path.is_file():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def load_config() -> dict:
    for name in ("aws-portal.json", "aws-portal.example.json"):
        p = HERE / name
        if p.is_file():
            cfg = json.loads(p.read_text())
            cfg["_source"] = name
            return cfg
    raise SystemExit("no aws-portal.json or aws-portal.example.json in scripts/")


def resolve_id(acct: dict, dotenv: dict) -> str:
    """An account's id: explicit `id` if it looks real, else the named env var (os env or .env)."""
    raw = str(acct.get("id", "")).strip()
    if raw.isdigit() and len(raw) == 12:
        return raw
    var = acct.get("env_var", "")
    val = (os.environ.get(var) or dotenv.get(var) or "").strip()
    return val if val.isdigit() and len(val) == 12 else ""


def switch_role_url(account_id: str, role: str, label: str, color: str) -> str:
    q = {
        "roleName": role,
        "account": account_id,
        "displayName": label,
        "color": color.lstrip("#"),
    }
    return "https://signin.aws.amazon.com/switchrole?" + "&".join(
        f"{k}={quote(str(v))}" for k, v in q.items() if v
    )


def render(cfg: dict, dotenv: dict) -> str:
    esc = html.escape
    region = cfg.get("region", "us-east-1")
    roles = cfg.get("roles") or [{"name": "OrganizationAccountAccessRole", "label": "admin", "color": "F2B0A9"}]
    parts = ["""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Watch AWS portal</title>
<style>
 body{background:#0f172a;color:#e2e8f0;font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:2rem}
 h1{font-size:1.25rem;margin:0 0 .25rem} .sub{color:#94a3b8;font-size:.85rem;margin:0 0 1.5rem}
 .card{background:#1e293b;border:1px solid #334155;border-radius:.6rem;padding:1rem 1.15rem;margin:0 0 1rem;max-width:640px}
 .card h2{font-size:1rem;margin:0 0 .1rem;display:flex;align-items:center;gap:.5rem}
 .chip{width:.7rem;height:.7rem;border-radius:2px;display:inline-block}
 .id{font-family:ui-monospace,Menlo,monospace;color:#94a3b8;font-size:.8rem;margin:0 0 .7rem}
 a.btn{display:inline-block;background:#334155;color:#e2e8f0;text-decoration:none;padding:.35rem .7rem;
   border-radius:.4rem;font-size:.85rem;margin:.15rem .3rem .15rem 0;border:1px solid #475569}
 a.btn:hover{background:#475569} a.portal{background:#4f46e5;border-color:#6366f1}
 .warn{color:#fbbf24;font-size:.85rem} code{background:#0f172a;padding:.05rem .3rem;border-radius:.3rem}
 footer{color:#64748b;font-size:.8rem;margin-top:1.5rem;max-width:640px}
</style></head><body>"""]
    parts.append(f"<h1>Watch — AWS access portal</h1>")
    parts.append(f'<p class="sub">region {esc(region)} · config <code>{esc(cfg.get("_source",""))}</code> · '
                 "sign into the management account (as an IAM user) first, then click a role.</p>")

    start = cfg.get("identity_center_start_url", "").strip()
    if start:
        parts.append(f'<p><a class="btn portal" href="{esc(start)}">↗ IAM Identity Center portal</a></p>')

    for acct in cfg.get("accounts", []):
        name = esc(acct.get("name", "account"))
        color = acct.get("color", "334155")
        acct_id = resolve_id(acct, dotenv)
        parts.append('<div class="card">')
        parts.append(f'<h2><span class="chip" style="background:#{esc(color)}"></span>{name}</h2>')
        if not acct_id:
            parts.append(f'<p class="warn">No account id — set <code>{esc(acct.get("env_var",""))}</code> '
                         "in your .env (or fill <code>id</code> in the config).</p></div>")
            continue
        parts.append(f'<p class="id">{esc(acct_id)}</p>')
        for role in roles:
            rn, rl = role.get("name", ""), role.get("label", role.get("name", ""))
            rc = role.get("color", color)
            url = switch_role_url(acct_id, rn, f"{acct.get('name','')} · {rl}"[:60], rc)
            parts.append(f'<a class="btn" href="{esc(url)}">switch role → {esc(rl)}</a>')
        parts.append("</div>")

    mgmt = cfg.get("management_account_id", "").strip()
    parts.append('<footer>Switch-role needs an active management-account session '
                 f'{("(" + esc(mgmt) + ") ") if mgmt else ""}as an IAM user — root can\'t switch roles. '
                 "For a real hosted portal, enable AWS IAM Identity Center (free) and set "
                 "<code>identity_center_start_url</code>.</footer>")
    parts.append("</body></html>")
    return "".join(parts)


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT") or 8765)
    cfg = load_config()
    dotenv = load_dotenv(ROOT / ".env")
    body = render(cfg, dotenv).encode()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            page = render(load_config(), load_dotenv(ROOT / ".env")).encode()  # re-read: live edits
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)

        def log_message(self, *_):  # quiet
            pass

    url = f"http://127.0.0.1:{port}/"
    httpd = HTTPServer(("127.0.0.1", port), Handler)
    n = sum(1 for a in cfg.get("accounts", []) if resolve_id(a, dotenv))
    print(f"Watch AWS portal → {url}   ({n} account(s) resolved from {cfg['_source']} + .env)")
    print("Ctrl-C to stop.")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
