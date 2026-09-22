# When checks or executable proof are unavailable

Continue detecting and recording source-backed findings. Automatic fixes and landing
require both the bug-specific expected-assertion red/green proof and a verified suite
comparison. An obvious-looking edit, manual approval, a build-only pass, or model votes
do not replace either gate.

Configure the project's existing native checks in `config/bugsweep.config.json` and a
pinned external execution policy. A command descriptor can name an argv array and its
JUnit output path; that output must be written beneath `/bugsweep-output` and captured
by the provider. No tests collected, setup/import errors, missing isolation, timeouts,
malformed results, and missing outputs remain proof errors.

If a check cannot emit stable native identities, its process result can be retained as
an opaque check, but it cannot detect individual failure swaps. Add a supported native
structured reporter before relying on test-level regression protection. Do not install
or download tools automatically to turn an unavailable capability into a pass.

Record the confirmed trigger, missing capability, existing project command, and next
concrete action in the normal tracker closeout. Preserve attempted work and its evidence.
