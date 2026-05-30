Restored to `bench-base` with no source files modified. After full static analysis plus an independent adversarial second read, the three shipping runtime files (`src/api.mjs`, `src/converter.mjs`, `src/assign.mjs`) match pristine js-cookie 3.0.5 exactly — including the easily-mutated encode/decode regexes verified hex-digit-by-hex-digit against the RFC 6265 cookie-octet set. No high-confidence runtime bug found; reporting none rather than manufacturing a false positive.

## Confirmed but not fixed
