# Generic anti-patterns (all stacks)

High-impact, language-independent patterns. For each, confirm a concrete trigger before
reporting.

## Authorization and access
- A resource is fetched/mutated by an ID from the request without checking the caller owns
  it (IDOR / broken object-level authorization). Smell: `getById(req.params.id)` with no
  ownership check. Bites: any user reads/edits any other user's data.
- Authentication is checked but authorization is not — logged-in ≠ allowed.
- Authz enforced in the UI/handler but not in the underlying service the handler calls, so
  a different caller of that service bypasses it. (An architectural-lens find.)

## Input handling and trust boundaries
- Untrusted input reaches a query/command/path/template without validation or
  parameterization (injection / traversal). Smell: string concatenation into SQL, shell,
  file paths, or HTML.
- Validation happens on one path to a sink but not another. Find the unguarded path.
- Trusting client-supplied values that should be server-derived (price, role, userId,
  isAdmin).

## Error handling
- Errors swallowed (empty catch, ignored return) so a failure looks like success.
- Error path returns a default/empty value that the caller treats as valid data.
- Missing null/undefined/None check on a value that can be absent (parse results, lookups,
  optional fields, env vars).

## State, money, time, data
- Read-modify-write on shared state without atomicity (lost updates, race). Smell:
  check-then-act across an await/IO boundary.
- Money in floats; rounding/truncation; mixing currencies/units.
- Naive datetime without timezone; assuming local time; DST and off-by-one-day at
  boundaries.
- Integer overflow / unbounded growth; truncation on cast or DB column width.
- Off-by-one in pagination, slicing, loops, and boundary comparisons (`<` vs `<=`).

## Secrets and config
- Hardcoded credentials/tokens/keys; secrets logged; secrets in URLs or error messages.
- Tokens/sessions without expiry or without server-side validation.

## Resource safety
- File/connection/lock opened on the happy path but not released on the error path.
- Unbounded retries or recursion; no timeout on outbound calls.
