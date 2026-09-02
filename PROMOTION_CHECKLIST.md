# Promotion Checklist

Fill this in before opening (or before merging) a PR from `gb_testing` into
`gb_stable`. Paste the completed checklist into the PR description — it's the
evidence behind the merge approval, which is what actually gates an image
from ever reaching `registry_manifest.json` (the manifest
`New-ComfyProject.ps1` reads for real client projects).

Do not merge the PR until every applicable box is checked.

## Which image is being promoted

- Testing image tag: `___________` (from `registry_manifest.testing.json`)
- Testing image digest: `sha256:___________`
- ComfyUI commit: `___________`

## Functional

- [ ] Basic txt2img workflow runs cleanly
- [ ] SDXL checkpoint loads without errors
- [ ] `Shared_Assets` models accessible via `extra_model_paths`
- [ ] Custom nodes in `Shared_Assets` load correctly
- [ ] Output files write to the correct project folder
- [ ] Port auto-detection works correctly

## Security

- [ ] Air-gapped mode confirmed (no outbound traffic when disabled)
- [ ] Container runs as non-root user (`comfyuser`)
- [ ] No unexpected ports exposed

## Compatibility

- [ ] Tested on an NVIDIA card (GPU model: `_________`)
- [ ] Tested on Windows Docker Desktop

## Sign-off

- Tested by: `___________`
- Date: `___________`
- Notes:
