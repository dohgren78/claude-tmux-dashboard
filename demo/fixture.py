"""Write the fake Claude Code state that demo.tape records.

Run by demo/run.sh with HOME pointing at the throwaway demo home. Every live
session is a `claude`-named sleep process in its own pane of the private
`cdash-demo` tmux server, so the dashboard's pid / tty / pane joins work for
real. Nothing here touches your own ~/.claude.
"""
import json, os, subprocess, sys, time, uuid


def dumps(obj):  # compact, like real Claude Code transcripts (the readers grep "key":"value")
    return json.dumps(obj, separators=(",", ":"))

HOME = os.environ["HOME"]
CODE = sys.argv[1]
CLAUDE = os.path.join(HOME, ".claude")
NOW = time.time()
SOCK = ["tmux", "-L", "cdash-demo"]


def slug(path):
    return path.replace("/", "-")


def transcript(sid, cwd, model, ctx_tokens, turns, last_prompt, age):
    d = os.path.join(CLAUDE, "projects", slug(cwd))
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, sid + ".jsonl")
    with open(path, "w") as fh:
        for user, reply in turns:
            fh.write(dumps({"type": "user", "sessionId": sid, "cwd": cwd, "isSidechain": False,
                                 "message": {"role": "user", "content": user}}) + "\n")
            fh.write(dumps({"type": "assistant", "sessionId": sid, "cwd": cwd, "isSidechain": False,
                                 "message": {"role": "assistant", "model": model,
                                             "content": [{"type": "text", "text": reply}],
                                             "usage": {"input_tokens": 9, "cache_creation_input_tokens": 2400,
                                                       "cache_read_input_tokens": max(ctx_tokens - 2409, 0),
                                                       "output_tokens": 640}}}) + "\n")
        fh.write(dumps({"type": "last-prompt", "lastPrompt": last_prompt, "sessionId": sid}) + "\n")
    os.utime(path, (NOW - age, NOW - age))
    return path


LIVE = [
    # tmux name, status, waitingFor, model, context tokens, seconds since activity, turns
    ("api-server", "waiting", "permission", "claude-opus-5-5", 420_000, 35, [
        ("Add rate limiting to the /login endpoint",
         "Added a token-bucket limiter (10 req/min per IP) in middleware/rate_limit.py and wired it into /login. Tests pass."),
        ("Also cover /password-reset",
         "Done. The limiter needs a new Redis key prefix. Run the migration now? It touches the shared cache config."),
    ]),
    ("web-app", "busy", "-", "claude-sonnet-5-5", 180_000, 4, [
        ("The checkout test is flaky on CI, find out why",
         "It races the payment mock: the mock resolves before the cart store hydrates. Rewriting the test to await hydration."),
    ]),
    ("ios-client", "busy", "-", "claude-opus-5-5", 710_000, 11, [
        ("Port the settings screen to the new design system",
         "Settings now uses DSList and DSToggle. Building the preview snapshots for light and dark mode next."),
    ]),
    ("data-pipeline", "shell", "-", "claude-sonnet-5-5", 330_000, 140, [
        ("Backfill last month's events into the warehouse",
         "Backfill is running in a background shell (day 12 of 30). I'll check row counts against the source when it finishes."),
    ]),
    ("infra", "idle", "-", "claude-haiku-4-5-20251001", 112_000, 3900, [
        ("Why did the staging deploy fail?",
         "The health check timed out: the new container needs 40s to warm up and the probe allows 30s. Raised it to 60s."),
    ]),
    ("docs-site", "idle", "-", "claude-opus-5-5", 90_000, 11000, [
        ("Write the getting-started page",
         "Drafted docs/getting-started.md with install, first run and a troubleshooting section. Ready for review."),
    ]),
]

SLEPT = [
    ("billing", "claude-opus-5-5", 260_000, 90000, "Reconcile the Stripe payouts report",
     "Payouts match except two refunds booked a day late; flagged both in the report."),
    ("search", "claude-sonnet-5-5", 150_000, 190000, "Tune the ranking for exact title matches",
     "Exact title matches now get a 2.5x boost; relevance tests updated."),
]

PAST = [  # extra conversations in api-server, for the R picker and the i demo
    ("4f2c9a1e-7b3d-4e8a-9c21-5d6e8f0a1b2c", 7200, "Why is p95 latency up since Tuesday?",
     "Tuesday's ORM upgrade dropped an index hint; the orders query does a full scan. Added the index back."),
    (str(uuid.uuid4()), 86400 * 2, "Write integration tests for the auth flow",
     "Added 14 integration tests covering login, refresh, logout and lockout."),
    (str(uuid.uuid4()), 86400 * 5, "Bump the Postgres driver and check breaking changes",
     "Bumped to 3.2. One breaking change (connection pool defaults); adjusted settings.py."),
]

sessions_dir = os.path.join(CLAUDE, "sessions")
os.makedirs(sessions_dir, exist_ok=True)
registry = []

for name, status, waiting, model, ctx, age, turns in LIVE:
    cwd = os.path.join(CODE, name)
    os.makedirs(cwd, exist_ok=True)
    sid = str(uuid.uuid4())
    subprocess.run(SOCK + ["new-session", "-d", "-s", name, "-c", cwd, "exec -a claude sleep 86400"], check=True)
    pid = int(subprocess.check_output(SOCK + ["display", "-p", "-t", name, "#{pane_pid}"]).decode().strip())
    transcript(sid, cwd, model, ctx, turns, turns[-1][0], age)
    with open(os.path.join(sessions_dir, f"{pid}.json"), "w") as fh:
        fh.write(dumps({"pid": pid, "sessionId": sid, "cwd": cwd, "status": status, "waitingFor": waiting,
                   "updatedAt": int((NOW - age) * 1000), "kind": "interactive", "entrypoint": "cli"}))
    registry.append((name, cwd))

with open(os.path.join(CLAUDE, ".claude-dash-slept"), "w") as fh:
    for name, model, ctx, age, prompt, reply in SLEPT:
        cwd = os.path.join(CODE, name)
        os.makedirs(cwd, exist_ok=True)
        sid = str(uuid.uuid4())
        transcript(sid, cwd, model, ctx, [(prompt, reply)], prompt, age)
        fh.write(f"{sid}\t{name}\t{cwd}\n")
        registry.append((name, cwd))

api = os.path.join(CODE, "api-server")
for sid, age, prompt, reply in PAST:
    transcript(sid, api, "claude-opus-5-5", 200_000, [(prompt, reply)], prompt, age)

for extra in ("mobile-api", "admin-portal"):  # registry projects that aren't running (n)
    os.makedirs(os.path.join(CODE, extra), exist_ok=True)
    registry.append((extra, os.path.join(CODE, extra)))

reg = os.path.join(HOME, ".config", "claude-project", "projects.tsv")
os.makedirs(os.path.dirname(reg), exist_ok=True)
with open(reg, "w") as fh:
    fh.writelines(f"{n}\t{p}\n" for n, p in registry)
