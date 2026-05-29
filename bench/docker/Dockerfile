# bugsweep-bench analysis image — minimal, glibc, non-root.
#
# Detect-only bugsweep environment. Deliberately MINIMAL: bugsweep finds bugs by
# reading code (its adversarial LLM loop + a python3-backed call-graph/
# reachability index), so the only runtime needs are bash+coreutils (base),
# git, jq, python3, and the `claude` CLI. Language toolchains (node/go) are NOT
# installed: they feed only bugsweep's fix-path regression checks (run_checks.sh),
# which are irrelevant to detect-only AND cannot fetch dependencies under the
# egress allow-list anyway.
#
# debian-slim (glibc) is chosen over alpine (musl) so the prebuilt `claude`
# native binary runs without libc surprises.
#
# Build via bench/docker/build.sh, which stages the bugsweep skill into the
# build context at ./skill/ and records the resulting image id for provenance.

FROM debian:bookworm-slim

# Pin the Claude Code CLI to the version validated on the host. Override at build
# time with --build-arg CLAUDE_VERSION=<x.y.z>.
ARG CLAUDE_VERSION=2.1.153

ENV DEBIAN_FRONTEND=noninteractive

# pipefail so a failed `curl` in the install pipe fails the build (DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime deps. curl + ca-certificates are needed at BUILD time to fetch the CLI;
# they are harmless at run time (egress is restricted to the proxy regardless).
# Exact apt point-versions churn on base refreshes; the analysis image is pinned
# by image id at use time (recorded in provenance), so we do not pin apt versions.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      python3 \
 && rm -rf /var/lib/apt/lists/*

# Install the Claude Code native CLI (standalone binary; no node runtime). The
# installer drops files under $HOME/.local; we install into a world-traversable
# location, expose the launcher on PATH, and run `claude --version` so the build
# FAILS LOUDLY here if the install layout changed.
RUN export HOME=/opt/claudehome \
 && curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}" \
 && ln -sf /opt/claudehome/.local/bin/claude /usr/local/bin/claude \
 && chmod -R a+rX /opt/claudehome \
 && claude --version

# Bake the bugsweep skill at a fixed, world-readable path. The entrypoint stages
# it into the runtime HOME (which is a writable tmpfs) for skill discovery.
COPY skill/ /opt/bugsweep-skill/
RUN chmod -R a+rX /opt/bugsweep-skill

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod a+rx /usr/local/bin/docker-entrypoint.sh

# Non-root by default; isolate.sh also pins --user 65534:65534 at run time.
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
