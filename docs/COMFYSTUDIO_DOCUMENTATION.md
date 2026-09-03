# ComfyStudio — Setup, Operations & Handoff Documentation

> **Status:** In Progress — Full pipeline proven end-to-end (testing build → manual GPU validation → promotion PR → stable build → approved manifest entry), and `New-ComfyProject.ps1` has been rebuilt to actually read the manifest and pin by digest. Automated logic verified; the two interactive prompts (image selection, network security) still need a real-terminal confirmation.
> **Last Updated:** September 2, 2026
> **Purpose:** Secure, reproducible, multi-user ComfyUI deployment for a VFX/animation studio using Docker, GitHub, GHCR, and (eventually) LucidLink

---

## Table of Contents

1. [Overview & Architecture](#1-overview--architecture)
2. [Repository Structure](#2-repository-structure)
3. [Local & LucidLink Folder Structure](#3-local--lucidlink-folder-structure)
4. [Prerequisites](#4-prerequisites)
5. [First-Time Admin Setup](#5-first-time-admin-setup)
6. [Artist Onboarding](#6-artist-onboarding)
7. [Daily Operations — Starting a Project](#7-daily-operations--starting-a-project)
8. [Image Management — Build & Promote Pipeline](#8-image-management--build--promote-pipeline)
9. [Security Model](#9-security-model)
10. [Known Issues & Remaining Work](#10-known-issues--remaining-work)
11. [Reference — Key Decisions & Rationale](#11-reference--key-decisions--rationale)

---

## 1. Overview & Architecture

ComfyStudio is a containerised ComfyUI deployment designed for a small VFX/animation studio with the following goals:

- **Security:** Every project runs in an isolated Docker container. Unvetted assets cannot contaminate other projects or the shared asset library.
- **Reproducibility:** Any archived project can be relaunched years later with the exact same ComfyUI version, Python packages, and base OS.
- **Multi-user:** Artists connect to their own container instance via a browser. No local Python or ComfyUI installation required on artist machines.
- **Version control:** All infrastructure (Dockerfile, dependencies, workflows) lives in GitHub. No undocumented local changes.

### The Full Chain of Trust

```
GitHub commit (ComfyUI source, pinned)
        ↓  built by
GitHub Actions (automated, no human intervention mid-build)
        ↓  produces
GHCR Docker image + SHA256 digest (immutable)
        ↓  recorded in
registry_manifest.json (version controlled in repo)
        ↓  referenced by
docker-compose.yml (written once at project creation, never changed)
        ↓  pulled by
Artist's Docker Desktop (exact reproducible environment)
```

### Branch Strategy

Real branch names in this repo (not the generic `studio-testing`/`studio-stable` placeholders used in earlier drafts of this doc):

```
upstream Comfy-Org/ComfyUI (the real ComfyUI project)
        ↓  admin pulls updates selectively into
master              ← this fork's default branch. Holds Dockerfile,
        │              workflows, and (eventually) the approved manifest.
        │              GitHub Actions only reads workflow files from here.
        ├── gb_testing   ← new versions land here, builds automatically,
        │                  writes to the UNAPPROVED registry_manifest.testing.json
        └── gb_stable     ← only receives merges via a reviewed/approved PR
                            from gb_testing. Builds automatically on merge,
                            writes to the APPROVED registry_manifest.json.
```

`gb_testing` and `gb_stable` are **siblings**, not parent/child — both branch off `master`, and `gb_stable` is a permanent branch that periodically receives a PR merge from `gb_testing`, not something re-created from it each time.

**Current reality check (2026-09-02):** `gb_stable` is badly out of sync — its latest commit (`a1c101f8`) is far behind `master`/`gb_testing` and shares no recent history with them. Nothing has ever been promoted through this pipeline. This is expected at this stage and not itself a bug — see Section 10.

---

## 2. Repository Structure

**GitHub Repo:** `github.com/adampcarroll/ComfyUI`
**Local clone:** `D:\ai\adampcarroll\ComfyUI`
**Default Branch:** `master`
**Remotes:** `origin` → `github.com/adampcarroll/ComfyUI.git`, `upstream` → `github.com/Comfy-Org/ComfyUI.git`

```
master (default branch)
├── .github/
│   └── workflows/
│       ├── build-testing.yml       # Auto-builds on push to gb_testing — EXISTS, fixed
│       └── build-stable.yml        # Auto-builds on push to gb_stable — EXISTS
├── docker/
│   ├── Dockerfile                  # Pinned base image, builds real Python 3.11 from source
│   └── requirements.lock           # Hash-verified Python dependency lockfile
├── registry_manifest.json          # APPROVED images only — EXISTS, has its first real entry
└── PROMOTION_CHECKLIST.md          # EXISTS, filled in for the first promoted image

gb_testing
├── [ComfyUI source, merged forward from master as needed]
└── registry_manifest.testing.json  # UNAPPROVED images — written by CI on every push here,
                                     # has 2 real entries so far

gb_stable
├── [ComfyUI source] — was very stale, first-ever promotion PR (#1) merged it forward
├── branch protection ENABLED (require PR before merge) — verified via GitHub API,
│   "protected": true. Exact rule contents (e.g. required approval count) not
│   independently re-verified beyond what the admin configured.
└── Does NOT carry its own live copy of registry_manifest.json going forward —
    build-stable.yml commits approved entries to master instead (see Section 8's
    "why master, not gb_stable" note). Any registry_manifest.json sitting in
    gb_stable's own tree (from the PR merge) is a stale snapshot, not canonical.
```

> **Important:** Workflow `.yml` files MUST live on the `master` (default) branch. GitHub Actions always reads workflows from the default branch regardless of which branch triggered the push. A file with build logic sitting only on `gb_testing` will silently never run — this actually happened (see Section 10) and was corrected.

### Why two manifest files, not one

`registry_manifest.json` is meant to be "the master list of **approved** production images" — it's what `New-ComfyProject.ps1` reads when spinning up a real client project. If the testing pipeline wrote directly into that file on every push (as an earlier draft of `build-testing.yml` did), an untested build could reach a real client project with zero human review. So:

- **`registry_manifest.testing.json`** (lives on `gb_testing`) — updated automatically by CI on every push. No gate. Used only by admins manually validating a build; never read by the project-creation script.
- **`registry_manifest.json`** (lives on `master`/`gb_stable`) — only updated by the *stable* build workflow, which only ever runs after a human has approved and merged a PR from `gb_testing` into `gb_stable`. The PR merge itself is the approval gate.

### Key Files

**`docker/Dockerfile`** (current, working version)
```dockerfile
FROM nvidia/cuda:13.0.0-runtime-ubuntu22.04@sha256:3e7f34f5e9dd5315b67ab30d71a92e578c5911236e14370647df020bdee2ca8a

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

# Code comes from GitHub Actions checkout, not a clone inside the container
COPY . .

COPY docker/requirements.lock .
RUN python3.11 -m pip install --require-hashes -r requirements.lock

# Non-root user for security
RUN useradd -m -u 1000 comfyuser && chown -R comfyuser /app
USER comfyuser

EXPOSE 8188
CMD ["sh", "-c", "exec python3.11 main.py --listen 0.0.0.0 $CLI_ARGS"]
```

**`registry_manifest.testing.json`** (`gb_testing` — 5 real entries as of the `CLI_ARGS` fix build; newest is the one to test against)
```json
{
  "tag": "3af2690",
  "digest": "sha256:81a2825f1f8449ad570cd4771c71d398e5595751689534e238b7c3040a0077a4",
  "comfyui_commit": "3af2690710f035da3640f1b02926a1ead8ecd931",
  "built_date": "2026-09-02",
  "branch": "gb_testing"
}
```
This is the image that has the `CLI_ARGS` fix — earlier entries (`7c4bede`, `61b6b42`, `8399545`, `2df2fff`) predate it. Note `tag` is the real short-sha tag that was actually pushed to GHCR (e.g. `docker pull ghcr.io/adampcarroll/comfyui-studio:3af2690` works) — an earlier version of this workflow recorded a fabricated `<date>-<short-sha>` string here that was never a real tag; see Section 10.

**`registry_manifest.json`** (approved/stable manifest, `master` — real content, first promoted image)
```json
{
  "images": [
    {
      "tag": "stable-b9e4efb",
      "digest": "sha256:1710f72bde44199ff6d372dbc5e41d935d1a69fa0a813adc8a20eeea40bae3a9",
      "comfyui_commit": "b9e4efbe49a1ff3601ea98a2891d67e5159f8ead",
      "built_date": "2026-09-02",
      "branch": "gb_stable"
    }
  ]
}
```
This entry was added by hand, not by CI — see Section 10 for why (`build-stable.yml`'s first run failed at exactly this step, root cause and fix documented there).

**`.github/workflows/build-testing.yml`** (current, working version)
```yaml
name: Build Studio ComfyUI Image

on:
  push:
    branches:
      - gb_testing   # only builds when YOU decide to update

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: write   # needed to commit registry_manifest.testing.json back
      packages: write   # needed to push to GHCR

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Get short commit hash
        id: vars
        run: echo "SHORT_SHA=${GITHUB_SHA::7}" >> $GITHUB_OUTPUT

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./docker/Dockerfile
          push: true
          tags: |
            ghcr.io/adampcarroll/comfyui-studio:latest
            ghcr.io/adampcarroll/comfyui-studio:${{ steps.vars.outputs.SHORT_SHA }}
          build-args: |
            COMFYUI_COMMIT=${{ github.sha }}

      - name: Capture digest
        run: |
          echo "Image digest: ${{ steps.build.outputs.digest }}"
          echo "TAG=${{ steps.vars.outputs.SHORT_SHA }}" >> $GITHUB_ENV
          echo "DIGEST=${{ steps.build.outputs.digest }}" >> $GITHUB_ENV

      - name: Update testing manifest
        # Unapproved images only — never read by New-ComfyProject.ps1 for real
        # client projects. Only registry_manifest.json (stable) is approved.
        run: |
          DATE=$(date +%Y-%m-%d)
          NEW_ENTRY=$(cat <<EOF
          {
            "tag": "${DATE}-${{ steps.vars.outputs.SHORT_SHA }}",
            "digest": "${{ steps.build.outputs.digest }}",
            "comfyui_commit": "${{ github.sha }}",
            "built_date": "${DATE}",
            "branch": "${{ github.ref_name }}"
          }
          EOF
          )
          jq ".images += [${NEW_ENTRY}]" registry_manifest.testing.json > tmp.json
          mv tmp.json registry_manifest.testing.json
          git config user.name "github-actions"
          git config user.email "actions@github.com"
          git add registry_manifest.testing.json
          git commit -m "ci: add testing image ${DATE}-${{ steps.vars.outputs.SHORT_SHA }}"
          git pull --rebase
          git push
```

`build-stable.yml` exists on `master`, mirroring `build-testing.yml` except:
- `branches: [gb_stable]`
- Tags use a `stable-` prefix (`stable-latest`, `stable-<sha>`) instead of relying on `latest`
- Writes to `registry_manifest.json` instead of `registry_manifest.testing.json`
- **Commits that manifest update to `master`, not `gb_stable`** — the build/push steps still run against the `gb_stable` checkout (that's what triggered the workflow), but the manifest write step explicitly does `git fetch origin master && git checkout master` first. This is a fix, not the original design — see the "why master, not gb_stable" note below.

It has now run once, on the first-ever merged promotion PR (#1, `gb_testing` → `gb_stable`). The build/push half succeeded on that first run; the manifest-write half failed and had to be fixed — full story in Section 10.

---

## 3. Local & LucidLink Folder Structure

**Current phase:** everything runs locally on `D:\ai\ComfyStudio` while the pipeline is being validated. Migration to a LucidLink network drive (`L:\ComfyStudio`) is deliberately deferred until the git/CI pipeline is fully proven — do not move paths to `L:` until told to.

```
D:\ai\ComfyStudio\                      (future: LucidLink volume, e.g. L:\ComfyStudio\)
├── Shared_Assets\                  # Approved, reusable assets (read-only in containers)
│   ├── checkpoints\                # flat, top-level — some checkpoints live here directly
│   ├── custom_nodes\               # Vetted nodes only (ComfyUI-Manager, IPAdapter_plus, etc.)
│   ├── extra_model_paths.yaml      # tells ComfyUI where to find everything below — see note
│   ├── models\                     # mirrors ComfyUI's own native models/ folder taxonomy
│   │   ├── checkpoints\ (has its own subfolders, e.g. z-image\)
│   │   ├── loras\, vae\, controlnet\, text_encoders\, diffusion_models\, model_patches\
│   │   └── LLM\                    # non-standard — registered by a specific custom node, not base ComfyUI
│   └── workflows\
├── ComfyProject.Core.ps1           # shared logic: manifest read (via `git show`), image
│                                    # selection, folder/network/port setup, compose generation
├── New-ComfyProject.ps1            # artist-facing entry point — always reads the APPROVED
│                                    # master:registry_manifest.json, pins image by digest
├── New-ComfyProject-Testing.ps1    # ADMIN-ONLY entry point — reads the UNAPPROVED
│                                    # gb_testing:registry_manifest.testing.json instead
├── .archive\                       # old script iterations (new_client.ps1, Project_Start_01-06.ps1)
├── docker\                         # local scratch copy, not the source of truth (that's the git repo)
└── [per-client project folders, created by the script]
```

### `extra_model_paths.yaml` — a real bug found and fixed during GPU validation

The file that had been sitting in `Shared_Assets/` mapped every category (`vae`, `loras`, `controlnet`, `embeddings`, `clip`, `clip_vision`, `upscale_models`) directly under the mount root (e.g. `vae: vae` → `/shared_assets/vae`), with no `models/` prefix, and had no `text_encoders`/`diffusion_models` keys at all. But every actual model file was sitting under `Shared_Assets/models/<category>/`. Net effect: **only `checkpoints/` (flat) and `custom_nodes/` were ever actually visible to any container** — the rest of the shared model library was silently invisible, the whole time, to every project.

Confirmed against ComfyUI's own reference (`extra_model_paths.yaml.example` in the repo) and its actual folder taxonomy (`folder_paths.py`) — the official/current category list is:
```
checkpoints, configs, loras, vae, text_encoders, diffusion_models,
clip_vision, style_models, embeddings, diffusers, vae_approx,
controlnet, gligen, upscale_models, latent_upscale_models,
hypernetworks, photomaker, classifiers, model_patches,
audio_encoders, frame_interpolation, optical_flow
```
Every real category path needs the `models/` prefix (this is also why some workflow examples reference `models/clip/` or `models/unet/` — those are supported legacy aliases for `text_encoders`/`diffusion_models` respectively, not a different structure). Subfolders inside a category (e.g. `models/loras/sd15/`) are fine — ComfyUI recursively scans and shows them as a path prefix in the loader dropdown. `LLM` is not a base ComfyUI category at all — it's registered by a specific custom node (likely ComfyUI-QwenVL), so it only works if that node is actually installed.

Fixed `extra_model_paths.yaml` to prefix every category with `models/` (keeping `checkpoints` pointing at both the flat folder and `models/checkpoints`, via a multi-line value, so nothing already there stopped working), and added `text_encoders`/`diffusion_models`/`model_patches`. Re-verified working via a manual GPU test run (see Section 8's promotion checklist).

### Shared vs Project Assets

| Asset type | Location | Who can add |
|---|---|---|
| Approved checkpoints | `Shared_Assets/checkpoints/` | Admin only, after vetting |
| Approved custom nodes | `Shared_Assets/custom_nodes/` | Admin only, after vetting |
| Client-specific models | `Projects/[name]/models/` | Artist, scoped to that project |
| Unvetted test nodes | `Projects/[name]/custom_nodes/` | Artist, isolated to that project |
| Client deliverables | `Projects/[name]/output/` | Written by ComfyUI container |

---

## 4. Prerequisites

### All Machines (Admin & Artists)

| Requirement | Minimum Version | Notes |
|---|---|---|
| Docker Desktop | Latest stable | Windows, Mac supported |
| NVIDIA GPU Driver | 527.41 (Windows) | For CUDA 13.0 container support |
| LucidLink Client | Latest | Not required yet — only once migrated off `D:\ai` |
| GitHub account | — | Needs access to `adampcarroll/ComfyUI` |

### GPU Compatibility

| GPU Generation | Architecture | Supported |
|---|---|---|
| RTX 5090, 5080 etc | Blackwell | ✅ Full support (CUDA 13.x) |
| RTX 4090, 4080 etc | Ada Lovelace | ✅ Full support |
| RTX 3090, 3080 etc | Ampere | ✅ Full support |
| RTX 2080, 2070 etc | Turing | ✅ Full support |
| GTX 1080 and older | Pascal/older | ⚠️ May need legacy CUDA 12.6 image |
| AMD GPUs | — | ❌ Not currently supported |

### Admin-Only Additional Requirements

- Python 3.11.x + `pip-tools` 7.0+ (for regenerating `requirements.lock` — confirmed working locally: Python 3.11.9, pip-compile 7.6.1)
- Docker Desktop (used locally to test-build images before pushing — this caught two real bugs this session; see Section 10)
- GitHub CLI (`gh`) — **not currently installed locally.** Useful for pulling Actions log output without going through the web UI; install it if doing this kind of debugging often.
- Docker Desktop with access to push to GHCR

---

## 5. First-Time Admin Setup

Status of each step against the real repo, as of 2026-09-02:

### Step 1 — Fork & Configure the Repository ✅ Done
- Forked to `github.com/adampcarroll/ComfyUI`, `master` is default branch
- Branches `gb_testing` and `gb_stable` exist
- ✅ `gb_stable` branch protection enabled (require PR before merge). Verified via `GET /repos/adampcarroll/ComfyUI/branches/gb_stable` returning `"protected": true`. Exact rule contents not independently re-verified (that endpoint needs auth), but the branch is confirmed protected.

### Step 2 — Add Studio Files to Master ✅ Done
- `docker/Dockerfile` ✅
- `docker/requirements.lock` ✅
- `.github/workflows/build-testing.yml` ✅ (fixed this session)
- `.github/workflows/build-stable.yml` ✅ (added — never actually run yet)
- `registry_manifest.json` ✅ (added, empty — no promotion has run yet to populate it)
- `PROMOTION_CHECKLIST.md` ✅ (added as a real file)

### Step 3 — Generate requirements.lock ✅ Done (regenerated this session)

The working command, run inside a Linux container to match the target environment exactly (running `pip-compile` natively on Windows risks resolving Windows-only packages that don't exist in the Linux container):

```bash
docker run --rm -v "$(pwd)":/app -w /app python:3.11-slim bash -c \
  "pip install --quiet --upgrade pip pip-tools && \
   pip-compile requirements.txt --generate-hashes --allow-unsafe --output-file docker/requirements.lock"
```

`--allow-unsafe` is required — without it, `setuptools` is left unpinned, and `pip install --require-hashes` rejects any unpinned package at install time.

### Step 4 — Pin the Base Image Digest ✅ Done
Current pinned digest, verified via `docker pull` + `docker inspect` on 2026-09-02:
```
nvidia/cuda:13.0.0-runtime-ubuntu22.04@sha256:3e7f34f5e9dd5315b67ab30d71a92e578c5911236e14370647df020bdee2ca8a
```

### Step 5 — Trigger First Build ✅ Done — succeeded 2026-09-02
Two attempts were needed:
1. First attempt failed — `pip install --require-hashes` couldn't find `networkx==3.6.1`. Root cause: Ubuntu 22.04's `python3-pip` package binds to the system default Python (3.10), not the explicitly-installed 3.11, so hash resolution happened under the wrong interpreter/ABI.
2. Real root cause: Ubuntu 22.04's `python3.11` apt package itself (`jammy-updates/universe`) is permanently frozen at `3.11.0~rc1` and was never updated to a final release. Fixed by building CPython 3.11.16 from official source inside the Dockerfile, pinned by version + a checksum computed from the downloaded bytes (see Dockerfile in Section 2).
3. Second attempt succeeded. Image `ghcr.io/adampcarroll/comfyui-studio:2026-09-02-7c4bede` now exists, digest `sha256:ffdf411919ffbb1c335f2924faea8d83d18f2bb453fc990bd5952274eb563629`.

### Step 6 — Authenticate to GHCR
Not yet re-verified from a second (artist-like) machine this session — only confirmed the build pushes successfully from CI.

### Step 7 — Set Up LucidLink Folders
Deferred — staying on `D:\ai\ComfyStudio` until the pipeline is fully proven (explicit decision, see Section 3).

### Step 8 — Configure the PowerShell Script
Done. `Project_Start_06.ps1` (hardcoded to `comfyui-studio:2025-01-15`) has been replaced by `ComfyProject.Core.ps1` + two thin entry points, per the planned core+entry-points design. The core script reads whichever manifest it's told to via `git show <branch>:<file>` (works regardless of which branch is checked out locally) and pins the generated `docker-compose.yml` to the image **by digest**, never a mutable tag. `New-ComfyProject.ps1` (stable) and `New-ComfyProject-Testing.ps1` (admin-only, unapproved images) are both real files now — old `Project_Start_04/05/06.ps1` moved to `.archive/`.

Verified automatically: manifest reading, image listing, default-to-newest selection, digest-pinned compose generation, folder/README creation, port auto-detection. **Still needs a real-terminal confirmation** of the two interactive prompts (image-number selection, network security Y/N) — this tool's non-interactive environment can't exercise those.

---

## 6. Artist Onboarding

Not yet exercised — no artist machine has been set up against this pipeline. Steps below are still the plan, unchanged from the original design:

### Step 1 — Install Docker Desktop
Download from [docker.com](https://docker.com). Accept defaults. Restart when prompted.

### Step 2 — Verify GPU Driver
```powershell
nvidia-smi
# Check Driver Version is 527.41 or higher
```

### Step 3 — Install and Mount LucidLink
Not applicable yet — project currently lives on `D:\ai`, not a shared network drive.

### Step 4 — Authenticate to GHCR
```powershell
docker login ghcr.io
# Ask admin for the studio GitHub PAT token, or use a personal GitHub account added to the org
```

### Step 5 — Test a Container Launch
```powershell
cd D:/ai/ComfyStudio/Projects/test-project
docker compose up -d
# Open browser to: http://localhost:8188
```

---

## 7. Daily Operations — Starting a Project

Live now, per the actual rebuilt script (see Section 5 Step 8).

### Creating a New Project (Admin or Lead)

```powershell
cd D:\ai\ComfyStudio
.\New-ComfyProject.ps1 -ClientName "Acme Corp Spot"
```

For admins validating a testing build before promotion (not for real client work):
```powershell
.\New-ComfyProject-Testing.ps1 -ClientName "Internal Validation Run"
```

Actual behavior:
1. Reads the manifest (`master:registry_manifest.json` for the artist-facing script, `gb_testing:registry_manifest.testing.json` for the testing one) via `git show`
2. Lists available images, prompts which one to use (default: newest)
3. Sanitizes the client name into a URL-safe slug (`acme-corp-spot`)
4. Prompts whether to enable internet access (default: No / air-gapped)
5. Auto-detects the next available port
6. Creates the full folder structure under `D:\ai\ComfyStudio\<slug>\`
7. Writes a `docker-compose.yml` pinned to the selected image **by digest** (never a mutable tag)
8. Writes a `PROJECT_README.txt` with port, security status, image, and manifest source
9. Copies the compose content to clipboard

### Launching / Stopping / Archiving / Relaunching a Project
Unchanged from original design — see Appendix for the exact commands.

---

## 8. Image Management — Build & Promote Pipeline

### The Pipeline (now proven end-to-end, 2026-09-02)

```
Push to gb_testing
   → build-testing.yml builds automatically → PROVEN WORKING
   → Testing image in GHCR, tag ghcr.io/adampcarroll/comfyui-studio:<short-sha>
   → Entry auto-appended to registry_manifest.testing.json (no gate — unapproved by design)
   → Admin validates against PROMOTION_CHECKLIST.md → PROVEN, validated on real RTX 5090 hardware
   → Admin opens a PR: gb_testing → gb_stable → PROVEN (PR #1)
   → PR reviewed and merged (branch protection — this merge IS the approval gate) → PROVEN
   → build-stable.yml builds automatically → PROVEN (image build/push half)
   → Stable image in GHCR (ghcr.io/adampcarroll/comfyui-studio:stable-<short-sha>) → PROVEN
   → registry_manifest.json (approved) updated → had to be fixed + entered manually
     the first time (CI's own commit was blocked by gb_stable's branch protection —
     see "Why master, not gb_stable" below); automatic for future promotions
   → Available for New-ComfyProject.ps1 to use for real client projects → NOT YET WIRED UP
```

**First real promotion, PR #1, is done.** `gb_stable` merged commit `b9e4efbe49a1ff3601ea98a2891d67e5159f8ead`, image `ghcr.io/adampcarroll/comfyui-studio:stable-b9e4efb` (digest `sha256:1710f72bde44199ff6d372dbc5e41d935d1a69fa0a813adc8a20eeea40bae3a9`) is in `registry_manifest.json`. The only unproven piece left in the whole pipeline is the very last arrow: `New-ComfyProject.ps1` actually reading and using this manifest.

### What a Pull Request actually is, for reference
A PR is GitHub's mechanism for proposing "merge branch A into branch B" as a reviewable, approvable action instead of a direct push. `gb_stable` now has branch protection enabled (confirmed via API: `"protected": true`), so GitHub refuses direct pushes to it — the only way changes land is through an approved, merged PR. That PR merge is what makes "promotion" a real security gate: an unreviewed image cannot physically reach `gb_stable`, and therefore cannot reach `registry_manifest.json`, without a human clicking merge.

### Promotion Checklist (`PROMOTION_CHECKLIST.md` — real file, repo root)

Same content as the original template, plus a header identifying exactly which image is being promoted (tag/digest/commit) so it's unambiguous what the checklist was actually run against:

```markdown
# Promotion Checklist

## Which image is being promoted
- Testing image tag: ___________
- Testing image digest: sha256:___________
- ComfyUI commit: ___________

## Functional
- [ ] Basic txt2img workflow runs cleanly
- [ ] SDXL checkpoint loads without errors
- [ ] Shared_Assets models accessible via extra_model_paths
- [ ] Custom nodes in Shared_Assets load correctly
- [ ] Output files write to correct project folder
- [ ] Port auto-detection works correctly

## Security
- [ ] Air-gapped mode confirmed (no outbound traffic when disabled)
- [ ] Container runs as non-root user (comfyuser)
- [ ] No unexpected ports exposed

## Compatibility
- [ ] Tested on an NVIDIA card (GPU model: _________)
- [ ] Tested on Windows Docker Desktop

## Sign-off
- Tested by: ___________
- Date: ___________
- Notes:
```

The idea: this checklist gets filled in and pasted into the PR description before anyone approves the `gb_testing` → `gb_stable` merge, so the completed checklist is the evidence behind the approval.

### Updating registry_manifest.json (stable)

`build-stable.yml` handles this automatically on merge — but writes to `master`, not `gb_stable`. Manual fallback (same as the original design, and what actually happened for the very first entry): copy the digest from the Actions build log — or `docker pull` the tag yourself and read `docker inspect --format='{{index .RepoDigests 0}}'` if the log isn't available — into `registry_manifest.json` on `master` by hand.

### Why `master`, not `gb_stable`, for the approved manifest commit

This wasn't the original design — it's a fix. The first real promotion (PR #1) revealed a genuine conflict: `build-stable.yml`'s manifest-update step tried to `git push` its commit directly to `gb_stable`, but `gb_stable` now has branch protection (require PR before merge) enabled, which blocks *all* direct pushes — including from the workflow's own `GITHUB_TOKEN`, not just from a human. The build/push steps succeeded (a real image landed in GHCR), but the manifest-write step failed outright. Fixed by having that step commit to `master` instead, which has no protection and is the documented canonical home for `registry_manifest.json` anyway. `gb_stable` now never receives an auto-commit — it only ever changes via a merged PR, which is arguably more correct than the original design.

---

## 9. Security Model

### Container Isolation
Each project runs in its own Docker container with its own port, its own `input/`, `output/`, `custom_nodes/`, `models/` folders, read-only access to `Shared_Assets/`, and no access to other project folders.

### Network Security

| Mode | Description | Use When |
|---|---|---|
| Air-Gapped (default) | No outbound internet traffic | NDA projects, sensitive clients |
| Internet Enabled | Full outbound access | Installing new nodes via ComfyUI Manager |

### Custom Node Policy
Custom nodes are arbitrary Python code — treat them like executable files. `Shared_Assets/custom_nodes/` is vetted-only, admin-reviewed; `Projects/[name]/custom_nodes/` is unvetted, isolated to one project.

### Image Trust Chain
Every image is built from a pinned git commit, built on GitHub Actions (no human intervention mid-build), referenced by SHA256 digest (never a mutable tag) in `docker-compose.yml`, and recorded with full provenance in a registry manifest.

### The registry manifest split IS a security control
See Section 2's explanation of `registry_manifest.testing.json` vs `registry_manifest.json`. This isn't just data organization — it's what prevents an unapproved testing build from ever being handed to a real client project.

### Recommended Docker Compose Security Additions
Not yet added to the PowerShell script's compose generation (see Section 10):
```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
deploy:
  resources:
    limits:
      cpus: '8.0'
      memory: 32G
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

---

## 10. Known Issues & Remaining Work

### Resolved this session (2026-09-02)
- ~~Trigger first test build~~ — done, succeeded on second attempt
- ~~Verify GHCR pull~~ — confirmed image + digest landed in GHCR
- `build-testing.yml` branch trigger typo (`gb-testing` vs real `gb_testing`) — fixed
- `build-testing.yml` missing `file: ./docker/Dockerfile` path — fixed
- Duplicate workflow file (`build-studio-image.yml` on `gb_testing`, byte-identical to `master`'s `build-testing.yml`) — deleted
- CI auto-writing to the approved manifest from the unapproved testing pipeline — fixed by splitting into `registry_manifest.testing.json` (testing) / `registry_manifest.json` (stable, gated by PR merge)
- `pip install --require-hashes` running under the wrong Python (3.10 via `python3-pip`) instead of 3.11 — fixed
- Ubuntu 22.04's `python3.11` apt package frozen at `3.11.0~rc1` — fixed by building real CPython 3.11.16 from source, pinned by version + checksum
- `Dockerfile` `CMD ["python", ...]` — `python` binary doesn't exist on Ubuntu 22.04 by default — fixed to `python3.11`
- `requirements.lock` missing a pin for `setuptools`, which `--require-hashes` rejects — regenerated with `--allow-unsafe`
- `gb_testing` was missing the entire `docker/` folder — fixed by merging `master` into it

### Resolved in the follow-up session (still 2026-09-02)
- ~~Verify `gb_stable` branch protection~~ — enabled by the user, confirmed via API (`"protected": true`)
- ~~Create `PROMOTION_CHECKLIST.md`~~ — added as a real file, includes an "image being promoted" header (tag/digest/commit) plus the original Functional/Security/Compatibility/Sign-off sections
- ~~Write `build-stable.yml`~~ — added, mirrors `build-testing.yml`, triggers on `gb_stable`, writes `registry_manifest.json` with `stable-` tag prefix
- ~~Create empty `registry_manifest.json` on `master`~~ — done

### Resolved in the promotion-day session (still 2026-09-02)
- ~~Fill in `PROMOTION_CHECKLIST.md`~~ — done for image `7c4bede`, scope deliberately limited to what the image itself controls (compose-level items like air-gap/port-auto-detect explicitly marked out of scope until the PowerShell script is wired up)
- ~~Fabricated tag mismatch~~ — both `build-testing.yml` and `build-stable.yml`'s manifest-update steps recorded a made-up `<date>-<short-sha>` string as the image `tag`, but the actual pushed docker tag was always just `<short-sha>` (or `stable-<short-sha>`) — anyone pulling by the recorded tag got `not found`. Fixed to record the real tag; corrected the one existing bad entry.
- ~~Exercise a full promotion~~ — **done.** PR #1 (`gb_testing` → `gb_stable`) opened and merged by the user. `build-stable.yml` fired for the first time.
- ~~`build-stable.yml` push conflicts with `gb_stable` branch protection~~ — the manifest-update step tried to `git push` its commit directly to `gb_stable`, which now blocks all direct pushes (including from the workflow's own token) — this is exactly why it failed on the very first real run, even though the image build/push itself succeeded. Fixed: that step now commits to `master` instead. First entry in `registry_manifest.json` was added by hand (digest confirmed by pulling the image directly) since CI didn't get to do it.
- `gb_stable` being stale turned out not to matter in practice — the huge diff (many months of upstream ComfyUI history) merged without conflict.

### Resolved during pre-script verification (still 2026-09-02)
- ~~Confirm `Shared_Assets/custom_nodes` actually loads~~ — **confirmed working**, and confirmed thoroughly: `extra_model_paths.yaml`'s `custom_nodes` mapping causes ComfyUI to scan and attempt-load every package under `/shared_assets/custom_nodes`, not just run prestartup scripts. No change needed to `Project_Start_06.ps1`'s existing mount layout.
- ~~`CLI_ARGS` environment variable did nothing at all~~ — the Dockerfile's `CMD` was a bare exec-form array, which never invokes a shell and therefore never expands `$CLI_ARGS`. Verified by running the container with `CLI_ARGS` unset vs. set to a real flag: byte-identical output either way. `extra_model_paths.yaml` only ever loaded via ComfyUI's own auto-detection of that filename at its default path, unrelated to any flag. Fixed to `CMD ["sh", "-c", "exec python3.11 main.py --listen 0.0.0.0 $CLI_ARGS"]` — the `exec` keeps `python3.11` as PID 1 (clean `docker stop` signal handling) while still letting `$CLI_ARGS` expand. Re-verified with `CLI_ARGS="--cpu ..."` actually taking effect.

### Flagged for later — found during pre-script verification, not fixed yet
- **3 of 5 `Shared_Assets/custom_nodes` packages fail to import**: `ComfyUI-Manager` (`No module named 'git'`), `comfyui_segment_anything` (`No module named 'segment_anything'`), `was-node-suite-comfyui` (`No module named 'numba'`). Root cause: each has its own `requirements.txt`, and the base image only ever installs ComfyUI's own `docker/requirements.lock` — nothing installs a mounted custom node's dependencies. Only `ComfyUI_IPAdapter_plus` and `rgthree-comfy` currently import cleanly. This is a real architectural decision, not a quick fix — the trade-off:
  - **Bake known shared-node deps into `requirements.lock`** — matches the "pin everything" philosophy, but couples image versioning to custom-node curation (adding a vetted node means a new image build, not just dropping a folder into `Shared_Assets`)
  - **Auto-install each node's `requirements.txt` at container startup** — more flexible, but runs arbitrary pip installs at runtime (cuts against the reproducibility/trust model this whole pipeline is built on, and wouldn't work in air-gapped mode at all)

### Resolved in the PowerShell rework session (still 2026-09-02)
- ~~Update `New-ComfyProject.ps1` to read the manifest~~ — done, per the core+entry-points design
- ~~Build the core+entry-points script structure~~ — done: `ComfyProject.Core.ps1` + `New-ComfyProject.ps1` (stable) + `New-ComfyProject-Testing.ps1` (admin-only, testing manifest). Reminder still applies: placing the testing script in the same visible folder is organizational clarity, not real access control.
- **New gotcha found:** a non-ASCII character (em-dash) inside a PowerShell string literal broke Windows PowerShell 5.1's parser outright (`The string is missing the terminator`), because the `.ps1` files have no UTF-8 BOM — without one, PowerShell 5.1 misreads multi-byte UTF-8 via the system codepage. Fix: keep PowerShell script content plain-ASCII; don't rely on BOM handling.

### Soon — still open
- [ ] Add `security_opt`/`cap_drop`/resource limits to the compose generation in the script
- [ ] Add CPU/RAM resource limits to the compose template
- [ ] Add `keys/` folder handling — project API keys should use Docker secrets or env var injection, not plaintext files
- [ ] Mount `input/` as read-only inside containers where workflows allow it
- [ ] Confirm the two interactive prompts (image selection, network security) behave correctly in a real terminal — only verified automatically so far, this tool can't exercise interactive input

### Later — operational improvements
- [ ] Add basic reusable test workflows (simple txt2img, checkpoint load) to `Shared_Assets/workflows/` so build/image verification doesn't rely on improvising a test each time — pairs with `PROMOTION_CHECKLIST.md`'s "Basic txt2img workflow runs cleanly" item
- [ ] Node allowlist/validation script — hash-check custom nodes before they run
- [ ] Audit log in the PowerShell script
- [ ] `promote-to-stable.ps1` helper — validates checklist is complete, opens PR via GitHub CLI (would need `gh` installed — not currently available locally)
- [ ] Artist onboarding doc — standalone doc for non-technical artists
- [ ] Portainer hardening (separate network, pinned digest image)
- [ ] Once the pipeline is fully proven on `D:\ai`, plan the migration to the live `L:\ComfyStudio` LucidLink drive

### Architecture decisions pending
- [ ] AMD GPU support — currently NVIDIA only
- [ ] Whether `New-ComfyProject.ps1` should ever be able to point at a testing image at all, vs. admins validating testing builds entirely outside the project-creation script

---

## 11. Reference — Key Decisions & Rationale

### Why Docker?
Isolates each project completely. A compromised or buggy custom node cannot affect other projects or the host machine.

### Why GitHub Actions + GHCR?
Free for private images on a GitHub org plan. Automated builds remove human error from image creation. GHCR integrates naturally with a GitHub-hosted repo.

### Why pin to a digest instead of a tag?
Docker tags are mutable. A SHA256 digest is mathematically tied to exact image contents — essential for archive/restore reproducibility.

### Why `requirements.lock` with hashes?
Without a lockfile, pip resolves whatever is current on PyPI at build time. The lockfile + hash verification ensures identical packages every build and rejects tampered packages. Must be generated with `--allow-unsafe` or `--require-hashes` will reject unpinned build tools like `setuptools` at install time.

### Why Python 3.11? (updated)
Best compatibility with PyTorch 2.12.x and ComfyUI custom nodes, supported with security fixes until October 2027. **Caveat discovered 2026-09-02:** Ubuntu 22.04's own `python3.11` apt package is not a viable way to get it — that package has been frozen at `3.11.0~rc1` since release and never received a final update. The fix used here is to compile CPython 3.11.16 from the official python.org source inside the Dockerfile, pinned by version + a checksum computed from the downloaded bytes. This was chosen over adding the (very reputable, but third-party) deadsnakes PPA, and over jumping to Ubuntu 24.04 (which drops 3.11 support entirely in favor of 3.12) — both were considered and rejected to keep the trust chain limited to python.org itself and avoid a much larger migration (new base digest, full lockfile regeneration, custom node re-validation) as a side effect of fixing a build error.

### Why CUDA 13.0 as base image?
PyTorch 2.12.0's stable release targets CUDA 13.0. Compatible with all modern NVIDIA architectures including Blackwell (RTX 5090). Older cards (Ampere, Turing) work fine with updated drivers.

### Why air-gap by default?
A container with no outbound network access cannot exfiltrate client data or download malicious content, even if a custom node contains malicious code. Internet access is an explicit opt-in decision made at project creation time.

### Why `gb_testing` before `gb_stable`?
New ComfyUI versions or dependency updates may break custom nodes or workflows. The testing branch provides a safe environment to validate before any production project is affected.

### Why two separate manifest files instead of one?
See Section 2. A single manifest, written to by both the testing and stable pipelines, would let an unapproved testing build reach `New-ComfyProject.ps1` with no human review. Splitting them makes the PR merge into `gb_stable` the actual security gate, not just a formality.

### Why test the Dockerfile locally before pushing to CI?
Docker Desktop is available on the admin machine. Building locally first (`docker build ...`) catches real errors in a couple of minutes instead of burning a full CI round-trip (~5 min queue + build) per guess. This caught both the wrong-Python-interpreter bug and the frozen-rc1 bug this session before they needed a third CI attempt.

---

## Appendix — Quick Reference Commands

```powershell
# Create a new project
.\New-ComfyProject.ps1 -ClientName "Client Name"

# Start / stop a project container
cd D:/ai/ComfyStudio/Projects/[project-slug]
docker compose up -d
docker compose down

# Check running containers / logs
docker ps
docker compose logs -f

# Authenticate to GHCR
docker login ghcr.io

# Regenerate requirements.lock (run inside a Linux container to match the
# target environment — running pip-compile natively on Windows can pull in
# Windows-only packages that don't exist in the Linux image)
docker run --rm -v "$(pwd)":/app -w /app python:3.11-slim bash -c \
  "pip install --quiet --upgrade pip pip-tools && \
   pip-compile requirements.txt --generate-hashes --allow-unsafe --output-file docker/requirements.lock"

# Get base image digest
docker pull nvidia/cuda:13.0.0-runtime-ubuntu22.04
docker inspect --format='{{index .RepoDigests 0}}' nvidia/cuda:13.0.0-runtime-ubuntu22.04

# Test-build the Dockerfile locally before pushing (catches errors in
# minutes instead of a full CI round-trip)
docker build --build-arg COMFYUI_COMMIT=test-local -f docker/Dockerfile -t comfyui-studio:local-test .
docker run --rm comfyui-studio:local-test python3.11 main.py --listen 0.0.0.0

# Trigger a test build (empty commit)
git checkout gb_testing
git commit --allow-empty -m "ci: trigger build"
git push origin gb_testing

# Check recent Actions runs without gh CLI (repo is public; read-only, no auth needed)
curl -s "https://api.github.com/repos/adampcarroll/ComfyUI/actions/runs?branch=gb_testing&per_page=5"

# Check GPU driver version
nvidia-smi
```

---

*This document should be kept up to date as the pipeline evolves. When handing off to another person or AI assistant, share this document along with the current state of the GitHub repository. The admin machine that did this work may also have a local, non-committed `CLAUDE_PROJECT_MEMORY.md` (or similarly named file) with a denser, session-level state dump intended for an AI assistant resuming work in progress — worth asking for if picking this up cold.*
