FROM ghcr.io/astral-sh/uv:0.13.6@sha256:af22a52f5eafef3d78e551599d405c02df61919d18028f0cea8eda93bc9986d0 AS uv
FROM rust:1.99.1-slim-trixie@sha256:b8e062b1c3a80183df83d9ba187cadd2b5ab84bc78d453dbfeb2fccd5f982247 AS rust
FROM python:3.15-slim@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913 AS builder
COPY --from=uv /uv /uvx /bin/
COPY --chmod=755 scripts/distrust_ca_roots.sh /usr/local/sbin/
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates cmake build-essential git libssl-dev zlib1g-dev libzstd-dev && rm -rf /var/lib/apt/lists/* && distrust_ca_roots.sh
COPY --from=rust /usr/local/rustup /usr/local/rustup
COPY --from=rust /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
WORKDIR /app
ENV UV_PYTHON_INSTALL_DIR=/app/.uv-python UV_PYTHON_PREFERENCE=only-managed
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --extra treesitter-full --extra sqlite-vec --no-install-local
COPY . .
RUN uv sync --frozen --no-dev --extra treesitter-full --extra sqlite-vec
FROM python:3.15-slim@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913
LABEL org.opencontainers.image.source="https://github.com/ciel-shieru/Biohazard"
COPY --chmod=755 scripts/distrust_ca_roots.sh /usr/local/sbin/
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ripgrep libssl3 zlib1g libzstd1 && rm -rf /var/lib/apt/lists/* && distrust_ca_roots.sh
RUN useradd --create-home appuser
USER appuser
WORKDIR /app
COPY --from=builder --chown=appuser:appuser /app/.uv-python /app/.uv-python
COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --from=builder --chown=appuser:appuser /app/codebase_rag /app/codebase_rag
COPY --from=builder --chown=appuser:appuser /app/codec /app/codec
COPY --from=builder --chown=appuser:appuser /app/cgr /app/cgr
COPY --from=builder --chown=appuser:appuser /app/pyproject.toml /app/pyproject.toml
ENV PATH="/app/.venv/bin:$PATH"
COPY --chmod=755 <<'EOF' /app/entrypoint.sh
#!/bin/sh
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) LIBDIR="/lib/x86_64-linux-gnu" ;;
    aarch64) LIBDIR="/lib/aarch64-linux-gnu" ;;
    *) LIBDIR="/lib" ;;
esac
export LD_PRELOAD="$LIBDIR/libz.so.1:$LIBDIR/libzstd.so.1"
exec code-graph-rag "$@"
EOF
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["mcp-server"]
