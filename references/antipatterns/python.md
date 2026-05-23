# Python / Django / Flask / FastAPI anti-patterns

## Language traps
- Mutable default argument (`def f(x, items=[])`) — the default is shared across calls.
- Bare `except:` or `except Exception: pass` swallowing errors.
- Late-binding closures in loops capturing the loop variable.
- `==` vs `is` for value comparison; truthiness of `0`, `""`, empty containers.
- Integer/float division and `Decimal` for money (floats lose precision).
- `assert` used for runtime validation (stripped under `-O`).

## Security
- SQL via f-strings/`%`/`.format` instead of parameterized queries / ORM bindings.
- `subprocess` with `shell=True` and interpolated input (command injection); prefer arg
  lists.
- `pickle`/`yaml.load` (non-safe)/`eval`/`exec` on untrusted input (RCE).
- Path from user input to `open`/`os.path.join` without containment (traversal).
- `requests` to a user-controlled URL (SSRF); `verify=False` disabling TLS checks.
- Secrets in source/settings committed to the repo; secrets in logs.

## Django
- Missing `select_related`/`prefetch_related` causing N+1 (perf, but can cascade to
  timeouts) — and conversely, querysets evaluated repeatedly.
- `objects.get()` without catching `DoesNotExist`/`MultipleObjectsReturned`.
- Permissions/`@login_required` on the view but object-level ownership unchecked (IDOR).
- `DEBUG=True` in production; overly broad `ALLOWED_HOSTS`; CSRF exemptions on mutating
  views.
- Mass-assignment via `ModelForm`/serializer `fields = '__all__'` exposing sensitive
  fields.

## Flask / FastAPI
- Async endpoint doing blocking IO on the event loop (FastAPI) — stalls the server.
- Pydantic model trusting client for fields that should be server-set (role, owner_id).
- Returning ORM objects that serialize sensitive fields.
- Global/module-level mutable state mutated per-request (not thread/async safe).

## Async
- Forgetting to `await` a coroutine (it becomes a coroutine object, never runs).
- `check-then-act` across `await`; shared state mutated by concurrent tasks.
