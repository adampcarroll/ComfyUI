# Promotion Checklist

Fill this in before opening (or before merging) a PR from `gb_testing` into
`gb_stable`. Paste the completed checklist into the PR description — it's the
evidence behind the merge approval, which is what actually gates an image
from ever reaching `registry_manifest.json` (the manifest
`New-ComfyProject.ps1` reads for real client projects).

Do not merge the PR until every applicable box is checked.

## Which image is being promoted

- Testing image tag: `7c4bede`
- Testing image digest: `sha256:ffdf411919ffbb1c335f2924faea8d83d18f2bb453fc990bd5952274eb563629`
- ComfyUI commit: `7c4beded2a688af6c0c08974e59de04f20b62269`

## Functional

- [x] Basic txt2img workflow runs cleanly
- [x] SDXL checkpoint loads without errors
- [x] `Shared_Assets` models accessible via `extra_model_paths` — **found and fixed a real bug during this validation**: `extra_model_paths.yaml` was missing the `models/` prefix on every category and had no `text_encoders`/`diffusion_models` mappings at all, so most of the shared model library was invisible to every container. Fixed and re-verified.
- [ ] Custom nodes in `Shared_Assets` load correctly — not explicitly re-verified this pass (should show in container startup log; `custom_nodes` mapping in `extra_model_paths.yaml` was already correct pre-fix)
- [ ] Output files write to correct project folder — **out of scope for this promotion**: no project `output/` volume exists yet to test against, since `New-ComfyProject.ps1` hasn't been wired up to this image pipeline
- [ ] Port auto-detection works correctly — **out of scope for this promotion**: this is a `New-ComfyProject.ps1` feature, not something a bare `docker run` exercises

## Security

- [ ] Air-gapped mode confirmed (no outbound traffic when disabled) — **out of scope for this promotion**: needs a real project's `docker-compose.yml` with `internal: true`, not tested against a bare `docker run`
- [x] Container runs as non-root user (`comfyuser`) — guaranteed by the Dockerfile's `USER comfyuser` directive (build-time, not overridden at runtime in any test this session)
- [x] No unexpected ports exposed — only `8188` was ever exposed/published; Dockerfile only `EXPOSE`s 8188

## Compatibility

- [x] Tested on an NVIDIA card (GPU model: `RTX 5090`)
- [x] Tested on Windows Docker Desktop

## Sign-off

- Tested by: `Adam Carroll`
- Date: `2026-09-02`
- Notes: First real end-to-end validation of the pipeline. Confirmed on real GPU hardware (RTX 5090 / Blackwell): clean startup, CUDA detected (32607 MB VRAM), Python 3.11.16 (confirms the source-build fix works outside the GPU-less dev machine), PyTorch 2.12.0+cu130, ComfyUI 0.20.1, basic txt2img generation succeeds. Scope of this promotion is deliberately limited to what the *image itself* controls (build integrity, GPU/CUDA correctness, model path resolution, non-root). Compose-level items (air-gapped network, port auto-detection, per-project output isolation, unverified custom-node load) remain open until `New-ComfyProject.ps1` is updated to actually use this pipeline — track those separately, don't treat this sign-off as covering them.
