# workflows

The CI and release patterns of the roxiegrillo and reinvsol repositories,
written once: how a repository checks its commits, proposes and publishes
releases with Release Please, and builds a release image. Repositories call
these instead of carrying their own copies.

## The rules

1. **Each commit is checked once.** Checks run on `pull_request` and on pushes
   to the default branch. A push to a pull request's branch would repeat the
   pull request's run, and a tag would repeat the default branch's.
2. **Release Please's pull request and release commit run no checks.** They
   change only `CHANGELOG.md` and `.release-please-manifest.json`, and the
   default branch has already checked the code they carry.
3. **A release image is built once, from its tag, with no second test run.**
   The release gate accepts a tag only when the checks of its parent commit,
   the code the release carries, have passed.
4. **Images are amd64 unless asked otherwise.** The lab is one amd64 node. Any
   other platform runs under QEMU unless the Dockerfile cross-compiles.

## What is here

| | What it does | Usable from |
|---|---|---|
| `release-please` action | Mints a release token from the automation App and runs Release Please | any repository |
| `service-released` action | Sends `service_released` to a service's plugin repository | any repository |
| `release-gate` action | Checks a release tag against the manifest, the default branch, its GitHub release and its parent's checks | any repository |
| `image` action | Builds, pushes and signs a tag's image once; a rerun never replaces a published image | any repository |
| `go-setup` action | The standard runner tools, Go, and read access to the owner's private modules | any repository |
| `release-please.yaml` workflow | Release Please, then `service-released` when a service publishes | roxiegrillo |
| `release-image.yaml` workflow | `release-gate` on the CI runner, then `image` on the build runner; signs as this repository (see below) | roxiegrillo |

A reusable workflow reaches the caller's self-hosted runners only when both
belong to the same organisation, so the workflows serve roxiegrillo and other
organisations call the actions from their own jobs. Everything else is the
same code.

## Using it

### Triggers for every CI workflow

Triggers always live in the calling repository.

```yaml
on:
  pull_request:
    paths-ignore: [CHANGELOG.md, .release-please-manifest.json]
  push:
    branches: [main]
    paths-ignore: [CHANGELOG.md, .release-please-manifest.json]

# A newer push to a pull request supersedes the run for the older commit.
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

A package whose release touches more files (a node release changes
`package.json`) skips Release Please's branch and commit with a job
condition instead, as `roxiegrillo/koba-human-friendly-ui` does.

### Release Please (roxiegrillo)

```yaml
name: Release
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  release:
    uses: roxiegrillo/workflows/.github/workflows/release-please.yaml@v1
    secrets: inherit
    with:
      plugin-repository: rate-router-cli # services only
```

### Release image

Call the `release-gate` and `image` actions from the repository's own release
workflow rather than `release-image.yaml`. A keyless signature names the
workflow that ran the signing job; in a reusable workflow that is
`roxiegrillo/workflows/.github/workflows/release-image.yaml@refs/tags/v1`, not
the repository's own release workflow at its tag. `lab-k8s-infra` verifies
goal-context's images by that identity, so a repository keeps it by running
the actions in its own jobs:

```yaml
name: Release image
on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      tag:
        description: Release tag to build, e.g. v1.2.3
        required: true
permissions:
  contents: read
jobs:
  gate:
    runs-on: ${{ vars.LAB_CI_RUNNER || 'lab-ci' }}
    permissions:
      contents: read
      checks: read
    outputs:
      tag: ${{ steps.gate.outputs.tag }}
    steps:
      - id: gate
        uses: roxiegrillo/workflows/release-gate@v1
        with:
          tag: ${{ inputs.tag || github.ref_name }}
  image:
    needs: gate
    runs-on: ${{ vars.LAB_BUILD_RUNNER || 'lab-build' }}
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: roxiegrillo/workflows/image@v1
        with:
          image: ghcr.io/roxiegrillo/rate-router
          tag: ${{ needs.gate.outputs.tag }}
          build-args: GITHUB_USERNAME=x-access-token
          client-id: ${{ vars.KOPO_CI_CLIENT_ID }}
          private-key: ${{ secrets.KOPO_CI_PRIVATE_KEY }}
          module-repositories: |
            koba
            koba-http
          module-token-secret: github_token
```

`module-repositories` narrows the module token; left empty, it reads every
repository the App reaches. A Dockerfile that reads a netrc file takes
`module-netrc-secret: netrc` instead of `module-token-secret`, and
`revision-arg`/`version-arg` name build arguments that receive the release
commit and tag. `release-image.yaml` wires the same two actions and suits a
repository whose signatures nobody verifies by identity.

The gate refuses a tag while its parent's checks are still running, so merge
a release pull request once the default branch is green, or run the workflow
again for the tag when they finish. A rebuild dispatched from the default
branch is signed with that branch's ref, not the tag's.

### From another organisation

```yaml
jobs:
  release-please:
    runs-on: reinvsol-ci
    steps:
      - uses: roxiegrillo/workflows/release-please@v1
        with:
          client-id: ${{ vars.<APP>_CLIENT_ID }}
          private-key: ${{ secrets.<APP>_PRIVATE_KEY }}
```

## Versioning

Release Please cuts `vX.Y.Z` from conventional commits, and each release moves
the major tag. Callers use `@v1`, so a fix reaches every repository without a
pull request of its own. A breaking change (an input removed or renamed, or a
behaviour a caller relies on) is a `feat!:` and ships as `v2`; `v1` stays where
it was.

## This repository

- It is public and holds workflow code only, never a secret or a value that
  must stay private.
- Its own checks run on GitHub's runners; lab runners serve private
  repositories only.
- Every third-party action is pinned to a full commit with its version in a
  comment; `scripts/check-actions.rb` holds the actions to that and to their
  declared inputs and outputs.
