# WU6 analysis image. Every executable and arm snapshot is staged locally by
# build.sh and verified again here; this file never downloads or installs a CLI.
ARG BENCH_BASE_IMAGE
FROM ${BENCH_BASE_IMAGE}

ARG CLAUDE_CLI_SHA256
ARG CODEX_CLI_SHA256
ARG ADAPTER_SHA256
ARG ARMS_SHA256

LABEL org.bugsweep.adapter.sha256=${ADAPTER_SHA256}
LABEL org.bugsweep.arms.sha256=${ARMS_SHA256}

USER root
COPY bin/claude /usr/local/bin/claude
COPY bin/codex /usr/local/bin/codex
COPY bench-host-adapter /usr/local/bin/bench-host-adapter
COPY runners/ /opt/bugsweep-bench/runners/
COPY arms/ /opt/bugsweep-benchmark-arms/
COPY arms.json /opt/bugsweep-benchmark-arms/arms.json

RUN test -n "${CLAUDE_CLI_SHA256}" \
 && test -n "${CODEX_CLI_SHA256}" \
 && test -n "${ADAPTER_SHA256}" \
 && test -n "${ARMS_SHA256}" \
 && test "$(sha256sum /usr/local/bin/claude | awk '{print $1}')" = "${CLAUDE_CLI_SHA256}" \
 && test "$(sha256sum /usr/local/bin/codex | awk '{print $1}')" = "${CODEX_CLI_SHA256}" \
 && test "$(sha256sum /usr/local/bin/bench-host-adapter | awk '{print $1}')" = "${ADAPTER_SHA256}" \
 && test "$(sha256sum /opt/bugsweep-benchmark-arms/arms.json | awk '{print $1}')" = "${ARMS_SHA256}" \
 && test -d /opt/bugsweep-benchmark-arms/current_skill \
 && test -d /opt/bugsweep-benchmark-arms/previous_release \
 && test -f /opt/bugsweep-benchmark-arms/baseline/NO_SKILL \
 && chmod 0555 /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/bench-host-adapter \
 && chmod -R a+rX /opt/bugsweep-bench /opt/bugsweep-benchmark-arms

USER 65534:65534
ENTRYPOINT ["/usr/local/bin/bench-host-adapter"]
