# docker/Dockerfile

# Pin your base image to a digest — get this by running:
# docker pull nvidia/cuda:12.3.1-runtime-ubuntu22.04
# docker inspect --format='{{index .RepoDigests 0}}' nvidia/cuda:12.3.1-runtime-ubuntu22.04
FROM nvidia/cuda:13.0.0-runtime-ubuntu22.04@sha256:3e7f34f5e9dd5315b67ab30d71a92e578c5911236e14370647df020bdee2ca8a

# Build arg injected by GitHub Actions — the exact commit to build from
ARG COMFYUI_COMMIT
RUN test -n "$COMFYUI_COMMIT" || (echo "COMFYUI_COMMIT is required" && exit 1)

# Ubuntu 22.04's own python3.11 apt package is permanently frozen at
# 3.11.0~rc1 (jammy-updates/universe never received a final-release
# update) — it's missing stdlib additions PyTorch 2.12 depends on.
# Build a real, patched CPython 3.11 from the official python.org source
# instead, pinned by version + a checksum computed from the actual
# downloaded bytes — same trust model as the base image digest above.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    zlib1g-dev \
    libssl-dev \
    libffi-dev \
    libbz2-dev \
    libsqlite3-dev \
    liblzma-dev \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

ARG PYTHON_VERSION=3.11.16
ARG PYTHON_SHA256=6c0bd76ab0ec7d94ed400b1497f01ac6c7751c8822615ee0855a3eb2d893ea76

RUN curl -fsSL -o /tmp/python.tgz https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz \
    && echo "${PYTHON_SHA256}  /tmp/python.tgz" | sha256sum -c - \
    && tar -xzf /tmp/python.tgz -C /tmp \
    && cd /tmp/Python-${PYTHON_VERSION} \
    && ./configure --with-ensurepip=install \
    && make -j"$(nproc)" \
    && make altinstall \
    && cd / && rm -rf /tmp/python.tgz /tmp/Python-${PYTHON_VERSION}

WORKDIR /app/ComfyUI

# Copy code from Actions checkout instead of cloning
COPY . .

# Install dependencies with hash verification
COPY docker/requirements.lock .
RUN python3.11 -m pip install --require-hashes -r requirements.lock

# Non-root user
RUN useradd -m -u 1000 comfyuser && chown -R comfyuser /app
USER comfyuser

EXPOSE 8188
CMD ["python3.11", "main.py", "--listen", "0.0.0.0"]
