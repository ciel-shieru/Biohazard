# Biohazard gVisor i915 runtime

This change adds a separate containerd handler (`runsc-i915`) and Kubernetes
RuntimeClass (`gvisor-i915`) backed by the pinned `ciel-shieru/gvisor` i915
proxy fork. Existing `runsc`, `runsc-kvm`, and Kata handlers remain unchanged.

## Runtime and path design

The custom Talos extension installs the forked `runsc-i915` and its matching
`gvisor-bin` sidecars under
`/usr/local/libexec/gvisor-i915/<full-commit>/`. It does not install a second
shim; the official `siderolabs/gvisor` extension still supplies
`containerd-shim-runsc-v1`.

`/etc/cri/conf.d/30-gvisor-i915.part` registers the distinct `runsc-i915`
handler and points `ConfigPath` to `/etc/cri/conf.d/runsc-i915.toml`. That TOML
sets `binary_name` to the absolute versioned `runsc-i915` path and enables
`i915proxy`. This handler does not rely on the default `runsc` executable path.
The Kubernetes RuntimeClass selects the CRI handler, not an executable path.

The `m720q` and `ms01` Talos profiles have different official extension sets,
so the build creates one installer for each profile on top of its own exact
Image Factory installer. Talhelper appends `:<talosVersion>` to `talosImageURL`;
the config therefore uses unique profile-and-commit-specific GHCR repositories
whose `v1.13.0` tags must be protected from mutation. The upgrade Task accepts
an optional `IMAGE` argument for the immutable digest reference.

The RuntimeClass selector requires
`gvisor-i915.home.arpa/enabled: "true"`. Talos config sets this label only on
the `m720q` and `ms01` anchors; `charlotte` and `chise` inherit `m720q`. Do not
apply the generated Talos config (and therefore the label) until the matching
custom installer has booted and its files have been checked.

## Security limitations

The fork is pinned to
`21f0865f92e48e6907bdf0a87ed804147cd3b1d1` (Bazel 8.8.1). It requires a
Linux/amd64 builder and builds through Podman's Docker-compatible CLI; do not
build this amd64 runtime on the Apple Silicon/macOS host. The build inputs
(Talos Image Factory base installer and Talos Imager) must use digest-pinned
references.

The i915 proxy is experimental and not hardware-validated by this change. It
supports DRM render nodes (`/dev/dri/renderD<N>`), not primary `card<N>` or
control nodes. It does not inspect GPU command buffers and is not an isolation
boundary between mutually untrusted GPU tenants. Biohazard's Intel GPU plugin
uses `sharedDevNum: 10`, so multiple Pods can share one physical GPU. Use this
runtime only within a single trust boundary; setting `sharedDevNum: 1` does not
create hardware isolation.

## Build the two installers

Use an isolated Linux/amd64 builder with Git, Make, Podman, tar, sha512sum,
Python 3, and standard core utilities. Authenticate Podman to GHCR. Resolve the
Secure Boot Image Factory installer URLs for all current nodes before updating
Talos config:

```bash
task t:run C=biohazard -- genurl installer --secure-boot --version v1.13.0
```

Capture the `RepoDigests` of the `m720q` schematic used by `ange`, `charlotte`,
and `chise`, and separately the `ms01` schematic used by `dorothy`. Also
capture the digest for `ghcr.io/siderolabs/imager:v1.13.0`. Then, from the
Biohazard repository root:

```bash
export OUT_DIR="$PWD/.out/gvisor-i915"
export TALOS_IMAGER_IMAGE='ghcr.io/siderolabs/imager:v1.13.0@sha256:REPLACE_WITH_64_HEX'

PROFILE=m720q \
BASE_INSTALLER_IMAGE='factory.talos.dev/installer-secureboot/M720Q_SCHEMATIC:v1.13.0@sha256:REPLACE_WITH_64_HEX' \
./hack/build-gvisor-i915-installer.sh

PROFILE=ms01 \
BASE_INSTALLER_IMAGE='factory.talos.dev/installer-secureboot/MS01_SCHEMATIC:v1.13.0@sha256:REPLACE_WITH_64_HEX' \
./hack/build-gvisor-i915-installer.sh
```

The script verifies the pinned source, builds the full gVisor release archive,
checks required sidecars, builds/pushes the custom Talos extension, and invokes
the digest-pinned Talos Imager on the profile-specific base. It writes the
archive plus `talos-installer-image-{m720q,ms01}.ref` digest files in `OUT_DIR`.
Make the final installer images public or configure pull credentials on every
Talos node. The extension image may remain private; the build script passes the
registry auth file read-only to Talos Imager.

## Validate and deploy

```bash
./hack/validate-gvisor-i915.sh
kustomize build kube/clusters/biohazard/config
task t:run C=biohazard -- genconfig
```

Review generated `machine.install.image` and node labels. Upgrade one node at a
time, using only its matching profile digest:

```bash
DNS_CLUSTER="$(op read 'op://biohazard/.biohazard-vars/DNS_CLUSTER')"
task t:upgrade C=biohazard NODE="ange.${DNS_CLUSTER}" VERSION=v1.13.0 \
  IMAGE="$(cat .out/gvisor-i915/talos-installer-image-m720q.ref)"
task t:upgrade C=biohazard NODE="dorothy.${DNS_CLUSTER}" VERSION=v1.13.0 \
  IMAGE="$(cat .out/gvisor-i915/talos-installer-image-ms01.ref)"
```

After each node reboots, verify these host paths before applying its generated
Talos MachineConfig to activate the RuntimeClass label:

```text
/usr/local/libexec/gvisor-i915/<full-commit>/runsc-i915
/usr/local/libexec/gvisor-i915/<full-commit>/gvisor-bin/gvisor_sentry
/etc/cri/conf.d/30-gvisor-i915.part
/etc/cri/conf.d/runsc-i915.toml
```

Check that `binary_name` matches the installed executable and that the CRI
fragment points to the shim TOML through `ConfigPath`. Verify the label and
RuntimeClass, replace the smoke Pod's placeholder with a real digest-pinned
image, then run:

```bash
kubectl get nodes -L gvisor-i915.home.arpa/enabled
kubectl get runtimeclass gvisor-i915 -o yaml
kubectl apply -f examples/i915-smoke-pod.yaml
kubectl describe pod gvisor-i915-smoke
kubectl logs gvisor-i915-smoke
```

The smoke Pod is non-root, drops all capabilities, disallows privilege
escalation, uses a read-only root filesystem and `RuntimeDefault` seccomp, and
does not mount a service-account token. It requests one `gpu.intel.com/i915`
resource and supplementary GID 44 (Biohazard's DRM udev group). Confirm the
allocated device is an i915 render node (not `xe`) and complete the fork's GPU
submission, synchronization, DMA-BUF, VA-API/QSV, OpenCL, and Vulkan tests on
each GPU model before production workloads.

## Upgrade and rollback

For a gVisor update, pin a new audited commit in the build script, update both
profile-specific `talosImageURL` repository paths, rebuild both installers,
and retain prior digests until validation is complete. Never overwrite old
profile/commit tags. Roll back with the previously recorded digest for the
matching profile, or restore previous installer paths and remove the
`gvisor-i915` RuntimeClass. Existing `runsc` and `runsc-kvm` handlers remain
independent.
