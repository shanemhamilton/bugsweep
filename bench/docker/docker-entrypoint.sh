#!/usr/bin/env bash
#
# Compatibility wrapper for the pinned WU6 host adapter. The trusted executor
# mounts only the evaluated source and its output scratch; the adapter selects
# an image-baked arm snapshot and never copies a benchmark checkout.

set -euo pipefail

exec /usr/local/bin/bench-host-adapter "$@"
