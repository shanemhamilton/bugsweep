Restored to `bench-base`; no files modified.

## Confirmed but not fixed
- BUGSWEEP-001 · high · security (prototype pollution / cookie attribute injection) · src/assign.mjs:5 · `for…in` copy lacks a `__proto__` guard, so an untrusted attributes object (`JSON.parse('{"__proto__":{…}}')`) sets `target`'s prototype, and `api.set`'s `for…in` then emits the inherited keys as injected cookie attributes.
