# syntax=docker/dockerfile:1

# ---- build ---------------------------------------------------------------
FROM python:3.12-slim AS build

WORKDIR /build

# Copy only what the build needs first, so dependency layers cache across
# source edits.
COPY pyproject.toml README.md ./
COPY src/ ./src/

RUN pip install --no-cache-dir --upgrade pip build \
    && python -m build --wheel --outdir /dist

# ---- runtime -------------------------------------------------------------
FROM python:3.12-slim AS runtime

LABEL org.opencontainers.image.title="cloud-cost-detective" \
      org.opencontainers.image.description="Explain why your cloud bill moved." \
      org.opencontainers.image.source="https://github.com/your-org/cloud-cost-detective" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# `git` is needed by the git change source; keep the rest of the image bare.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /dist/*.whl /tmp/
# Cloud SDKs are installed here rather than as core deps so the package stays
# light for anyone who only needs one provider.
RUN pip install --no-cache-dir /tmp/*.whl boto3 \
    && rm -rf /tmp/*.whl

# Run unprivileged. The UID is fixed so Kubernetes runAsUser matches.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin detective
USER 10001
WORKDIR /home/detective

# No HEALTHCHECK: this is a batch CLI, not a long-running service. The
# container runs once and exits, so there is nothing for Docker to poll.
# The CI smoke job verifies the entry point and packaged data instead.

ENTRYPOINT ["costdetective"]
CMD ["report", "--demo"]
