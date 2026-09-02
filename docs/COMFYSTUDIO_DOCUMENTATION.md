# ComfyStudio — Setup, Operations & Handoff Documentation

> **Status:** In Progress — First real test build succeeded on `gb_testing`. `gb_stable` now has branch protection (require PR before merge) and all the pieces needed to promote (`PROMOTION_CHECKLIST.md`, `build-stable.yml`, `registry_manifest.json`) exist, but a real promotion has never been exercised. `New-ComfyProject.ps1` does not yet read from the registry manifest.
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
├── registry_manifest.json          # APPROVED images only — EXISTS, empty ({"images": []})
└── PROMOTION_CHECKLIST.md          # EXISTS

gb_testing
├── [ComfyUI source, merged forward from master as needed]
└── registry_manifest.testing.json  # UNAPPROVED images — written by CI on every push here,
                                     # has 1 real entry from the first successful build

gb_stable
├── [ComfyUI source] — currently stale, last touched long before this pipeline existed
└── branch protection ENABLED (require PR before merge) — verified via GitHub API,
    "protected": true. Exact rule contents (e.g. required approval count) not
    independently re-verified beyond what the admin configured.
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
CMD ["python3.11", "main.py", "--listen", "0.0.0.0"]
```

**`registry_manifest.testing.json`** (real content as of first successful build)
```json
{
  "images": [
    {
      "tag": "2026-09-02-7c4bede",
      "digest": "sha256:ffdf411919ffbb1c335f2924faea8d83d18f2bb453fc990bd5952274eb563629",
      "comfyui_commit": "7c4beded2a688af6c0c08974e59de04f20b62269",
      "built_date": "2026-09-02",
      "branch": "gb_testing"
    }
  ]
}
```

**`registry_manifest.json`** (approved/stable manifest — created, still empty; will get its first entry once a promotion actually runs)
```json
{
  "images": []
}
```

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

`build-stable.yml` now exists on `master`, mirroring `build-testing.yml` except:
- `branches: [gb_stable]`
- Tags use a `stable-` prefix (`stable-latest`, `stable-<sha>`) instead of relying on `latest`
- Writes to `registry_manifest.json` instead of `registry_manifest.testing.json`

It has never actually run — `gb_stable` hasn't had a push (via merged PR) since it was added.

---

## 3. Local & LucidLink Folder Structure

**Current phase:** everything runs locally on `D:\ai\ComfyStudio` while the pipeline is being validated. Migration to a LucidLink network drive (`L:\ComfyStudio`) is deliberately deferred until the git/CI pipeline is fully proven — do not move paths to `L:` until told to.

```
D:\ai\ComfyStudio\                      (future: LucidLink volume, e.g. L:\ComfyStudio\)
├── Shared_Assets\                  # Approved, reusable assets (read-only in containers)
│   ├── checkpoints\
│   ├── custom_nodes\               # Vetted nodes only
│   ├── models\ (loras, vae, embeddings)
│   └── workflows\
├── Project_Start_04.ps1            # older iteration
├── Project_Start_05.ps1            # older iteration
├── Project_Start_06.ps1            # CURRENT active script — still hardcoded to a local
│                                    # image tag (comfyui-studio:2025-01-15), does NOT
│                                    # yet read registry_manifest.json. Rename/evolve to
│                                    # New-ComfyProject.ps1 once the manifest read is wired up.
├── .archive\                       # old script iterations (new_client.ps1, Project_Start_01-03.ps1)
├── docker\                         # local scratch copy, not the source of truth (that's the git repo)
└── [per-client project folders, created by the script]
```

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
Not done yet. `Project_Start_06.ps1` still hardcodes:
```powershell
$BaseStudioPath = "D:/ai/ComfyStudio"
$DockerImage = "comfyui-studio:2025-01-15"
```
It needs to be updated to read the image tag/digest from `registry_manifest.json` (the stable manifest) instead. See Section 10 for the planned script structure (core module + thin entry points, one for artists reading only the stable manifest, one admin-only for testing).

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

Still describes the target workflow — `New-ComfyProject.ps1` (renamed from `Project_Start_06.ps1`) has not been rewired to the registry manifest yet, so this isn't fully live.

### Creating a New Project (Admin or Lead)

```powershell
.\New-ComfyProject.ps1 -ClientName "Acme Corp Spot"
```

Planned behavior (current `Project_Start_06.ps1` already does most of this, minus the manifest read):
1. Sanitize the client name into a URL-safe slug (`acme-corp-spot`)
2. Prompt whether to enable internet access (default: No / air-gapped)
3. Auto-detect the next available port
4. Create the full folder structure under `Projects/`
5. Select the Docker image version from `registry_manifest.json` (not yet wired up — currently hardcoded)
6. Write a pinned `docker-compose.yml` for that project
7. Write a `PROJECT_README.txt` with port and security status
8. Copy the compose content to clipboard

### Launching / Stopping / Archiving / Relaunching a Project
Unchanged from original design — see Appendix for the exact commands.

---

## 8. Image Management — Build & Promote Pipeline

### The Pipeline (as actually designed and now partly proven)

```
Push to gb_testing
   → build-testing.yml builds automatically → PROVEN WORKING (2026-09-02)
   → Testing image in GHCR, tag ghcr.io/adampcarroll/comfyui-studio:<sha>
   → Entry auto-appended to registry_manifest.testing.json (no gate — unapproved by design)
   → Admin validates against PROMOTION_CHECKLIST.md (real file, repo root)
   → Admin opens a PR: gb_testing → gb_stable
   → PR reviewed and merged (branch protection now enabled — this merge IS the approval gate)
   → build-stable.yml builds automatically (exists on master — UNTESTED, never fired)
   → Stable image in GHCR
   → registry_manifest.json (approved) updated
   → Available for New-ComfyProject.ps1 to use for real client projects
```

**Nothing past "testing image in GHCR" has ever been exercised.** `gb_stable` has never received a promotion under this pipeline. All the pieces now exist (checklist, workflow, empty manifest, branch protection) — the first real promotion PR just hasn't happened yet.

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

`build-stable.yml` now handles this automatically on merge, the same way `registry_manifest.testing.json` already works for testing builds — but it has never actually fired, since no PR into `gb_stable` has ever been merged. First real promotion will be the first test of this.

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

### Immediate — before promoting anything to stable
- [ ] Actually exercise a full promotion: open a PR `gb_testing` → `gb_stable`, merge it, confirm `build-stable.yml` fires and the stable manifest updates. **Nothing has run this workflow yet — completely unverified.**
- [ ] `gb_stable` is currently very stale (last commit `a1c101f8`, far behind `master`) — the first real promotion PR will be large; consider whether to do it incrementally
- [ ] Fill in `PROMOTION_CHECKLIST.md` for the first testing image (tag `2026-09-02-7c4bede`) before opening that first PR

### Soon — before touching the PowerShell script
- [ ] Update `New-ComfyProject.ps1` (renamed from `Project_Start_06.ps1`) to read the image tag/digest from `registry_manifest.json` instead of the hardcoded `comfyui-studio:2025-01-15`
- [ ] Design agreed but not built: a shared core script/function (e.g. `ComfyProject.Core.ps1`) parameterized by which manifest to read, with two thin entry points — `New-ComfyProject.ps1` (artist-facing, stable manifest only) and an admin-only testing variant (calls the same core with the testing manifest). Note: hiding the testing script by not documenting it is obscurity, not real access control, unless it's also placed somewhere with actual restricted permissions.
- [ ] Add `security_opt`/`cap_drop`/resource limits to the compose generation in the script
- [ ] Add CPU/RAM resource limits to the compose template
- [ ] Add `keys/` folder handling — project API keys should use Docker secrets or env var injection, not plaintext files
- [ ] Mount `input/` as read-only inside containers where workflows allow it

### Later — operational improvements
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
