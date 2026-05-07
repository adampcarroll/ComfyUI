# docker/Dockerfile

# Pin your base image to a digest — get this by running:
# docker pull nvidia/cuda:12.3.1-runtime-ubuntu22.04
# docker inspect --format='{{index .RepoDigests 0}}' nvidia/cuda:12.3.1-runtime-ubuntu22.04
FROM nvidia/cuda:12.3.1-runtime-ubuntu22.04@sha256:REPLACE_WITH_REAL_DIGEST

# Build arg injected by GitHub Actions — the exact commit to build from
ARG COMFYUI_COMMIT
RUN test -n "$COMFYUI_COMMIT" || (echo "COMFYUI_COMMIT is required" && exit 1)

# System dependencies — pinned versions where possible
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11=3.11.* \
    python3-pip \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone your fork and checkout the exact commit
RUN git clone https://github.com/adampcarroll/comfyui.git ComfyUI && \
    cd ComfyUI && \
    git checkout $COMFYUI_COMMIT

WORKDIR /app/ComfyUI

# Install dependencies with hash verification (see note below)
COPY docker/requirements.lock .
RUN pip install --require-hashes -r requirements.lock

# Non-root user — important for security
RUN useradd -m -u 1000 comfyuser && chown -R comfyuser /app
USER comfyuser

EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0"]
