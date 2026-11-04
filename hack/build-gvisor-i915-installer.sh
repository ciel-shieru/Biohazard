#!/usr/bin/env bash
set -Eeuo pipefail

# Build the pinned gVisor fork, package only its runsc + sidecars as a Talos
# system extension, then layer that extension onto the Image Factory installer
# which already contains Biohazard's official Talos extensions.

readonly GVISOR_REPOSITORY="https://github.com/ciel-shieru/gvisor.git"
readonly GVISOR_COMMIT="21f0865f92e48e6907bdf0a87ed804147cd3b1d1"
readonly TALOS_VERSION="v1.13.0"
readonly GVISOR_REV_SHORT="${GVISOR_COMMIT:0:12}"
readonly EXTENSION_REPOSITORY_DEFAULT="ghcr.io/jjgadgets/gvisor-i915"
readonly INSTALLER_REPOSITORY_PREFIX="ghcr.io/jjgadgets/talos-installer-gvisor-i915"

: "${PROFILE:?Set PROFILE to m720q or ms01 so the installer uses the matching official extension set.}"
case "${PROFILE}" in
  m720q|ms01) ;;
  *) printf 'ERROR: PROFILE must be m720q or ms01.\n' >&2; exit 1 ;;
esac
: "${BASE_INSTALLER_IMAGE:?Set BASE_INSTALLER_IMAGE to the Image Factory installer for the Biohazard schematic, pinned with @sha256:<digest>.}"
: "${TALOS_IMAGER_IMAGE:?Set TALOS_IMAGER_IMAGE to ghcr.io/siderolabs/imager:v1.13.0@sha256:<digest>.}"

EXTENSION_REPOSITORY="${EXTENSION_REPOSITORY:-${EXTENSION_REPOSITORY_DEFAULT}-${PROFILE}-${GVISOR_COMMIT}}"
INSTALLER_REPOSITORY="${INSTALLER_REPOSITORY_PREFIX}-${PROFILE}-${GVISOR_COMMIT}"
REGISTRY_TAG="${TALOS_VERSION}"
INSTALLER_TAG="${TALOS_VERSION}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require git
require make
require podman
require tar
require sha512sum
require install
require mktemp
require sed
require grep
require find
require id

require_digest_ref() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    printf 'ERROR: %s must end in @sha256:<64 lowercase hex characters>.\n' "${name}" >&2
    exit 1
  fi
}
require_digest_ref BASE_INSTALLER_IMAGE "${BASE_INSTALLER_IMAGE}"
require_digest_ref TALOS_IMAGER_IMAGE "${TALOS_IMAGER_IMAGE}"

# Talos Imager uses go-containerregistry keychains inside the container. Mount
# the host's Podman/Docker auth file read-only so it can pull the private custom
# extension by digest. Do not copy credentials into the build context or image.
AUTH_FILE="${REGISTRY_AUTH_FILE:-${XDG_RUNTIME_DIR:-${HOME}/.config}/containers/auth.json}"
if [[ ! -r "${AUTH_FILE}" && -r "${HOME}/.docker/config.json" ]]; then
  AUTH_FILE="${HOME}/.docker/config.json"
fi
if [[ ! -r "${AUTH_FILE}" ]]; then
  printf 'ERROR: registry auth file is not readable; run podman login ghcr.io first.\n' >&2
  exit 1
fi

# This branch is built for Biohazard's amd64 Talos nodes. Refuse to silently
# publish an arm64 runsc binary when invoked from the user's Apple Silicon host.
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  printf 'ERROR: run this build on a Linux/amd64 builder (not macOS/arm64).\n' >&2
  printf 'A remote Linux/amd64 builder or an x86_64 Linux VM is suitable.\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Works both from the standalone bundle and after the files are copied into Biohazard.
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
for required_file in \
  "${ROOT_DIR}/hack/gvisor-i915/Containerfile" \
  "${ROOT_DIR}/hack/gvisor-i915/manifest.yaml.tmpl" \
  "${ROOT_DIR}/hack/gvisor-i915/runsc-i915.toml.tmpl" \
  "${ROOT_DIR}/hack/gvisor-i915/30-gvisor-i915.part"; do
  if [[ ! -f "${required_file}" ]]; then
    printf 'ERROR: required bundle file is missing: %s\n' "${required_file}" >&2
    exit 1
  fi
done
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/.out/gvisor-i915}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gvisor-i915-build.XXXXXXXX")"
cleanup() {
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

SRC_DIR="${WORK_DIR}/gvisor"
ARCHIVE_DIR="${WORK_DIR}/archive"
EXT_CONTEXT="${WORK_DIR}/extension-context"
IMAGER_OUT="${WORK_DIR}/imager-out"
ROOTFS="${EXT_CONTEXT}/rootfs"

mkdir -p "${OUT_DIR}" "${ARCHIVE_DIR}" "${EXT_CONTEXT}" "${ROOTFS}" "${IMAGER_OUT}"

printf '\n==> Pull and validate digest-pinned Talos build inputs\n'
podman pull "${BASE_INSTALLER_IMAGE}"
podman pull "${TALOS_IMAGER_IMAGE}"
for image in "${BASE_INSTALLER_IMAGE}" "${TALOS_IMAGER_IMAGE}"; do
  platform="$(podman image inspect --format '{{.Os}}/{{.Architecture}}' "${image}")"
  if [[ "${platform}" != linux/amd64 ]]; then
    printf 'ERROR: expected linux/amd64 image %s, got %s.\n' "${image}" "${platform}" >&2
    exit 1
  fi
done

printf '\n==> Fetch pinned gVisor source %s\n' "${GVISOR_COMMIT}"
git init -q "${SRC_DIR}"
git -C "${SRC_DIR}" remote add origin "${GVISOR_REPOSITORY}"
git -C "${SRC_DIR}" fetch --depth=1 origin "${GVISOR_COMMIT}"
git -C "${SRC_DIR}" checkout --detach -q FETCH_HEAD
ACTUAL_COMMIT="$(git -C "${SRC_DIR}" rev-parse HEAD)"
[[ "${ACTUAL_COMMIT}" == "${GVISOR_COMMIT}" ]] || {
  printf 'ERROR: fetched gVisor commit mismatch: expected %s, got %s\n' "${GVISOR_COMMIT}" "${ACTUAL_COMMIT}" >&2
  exit 1
}

printf '\n==> Build complete gVisor release fileset using Podman (no Buildx)\n'
# gVisor's Makefile uses its canonical Bazel builder container by default.
# DOCKER_CLI_PATH redirects its Docker-compatible CLI calls to Podman. The
# release build does not need a privileged builder or a mounted container socket.
make -C "${SRC_DIR}" \
  DOCKER_BUILD=true \
  DOCKER_CLI_PATH=podman \
  DOCKER_PRIVILEGED= \
  UNSANDBOXED_RUNTIME= \
  release-tarball \
  DESTINATION="${ARCHIVE_DIR}"

ARCHIVE="${ARCHIVE_DIR}/gvisor.tar.bz2"
test -s "${ARCHIVE}" || {
  printf 'ERROR: gVisor release archive was not produced: %s\n' "${ARCHIVE}" >&2
  exit 1
}
ARCHIVE_ARTIFACT="gvisor-${GVISOR_COMMIT}.tar.bz2"
install -m 0644 "${ARCHIVE}" "${OUT_DIR}/${ARCHIVE_ARTIFACT}"
(
  cd "${OUT_DIR}"
  sha512sum "${ARCHIVE_ARTIFACT}" > "${ARCHIVE_ARTIFACT}.sha512"
)

printf '\n==> Validate gVisor release layout\n'
TAR_LIST="${WORK_DIR}/archive.list"
tar -tjf "${ARCHIVE}" > "${TAR_LIST}"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "${TAR_LIST}"; then
  printf 'ERROR: release archive contains an unsafe path.\n' >&2
  exit 1
fi
grep -Eq '^\./?runsc$' "${TAR_LIST}" || {
  printf 'ERROR: release archive does not contain runsc at its root.\n' >&2
  exit 1
}
grep -Eq '^\./?gvisor-bin/gvisor_sentry$' "${TAR_LIST}" || {
  printf 'ERROR: release archive does not contain gvisor-bin/gvisor_sentry.\n' >&2
  exit 1
}

printf '\n==> Assemble Talos extension rootfs\n'
EXTRACT_DIR="${WORK_DIR}/extract"
mkdir -p "${EXTRACT_DIR}"
tar --no-same-owner --no-same-permissions -xjf "${ARCHIVE}" -C "${EXTRACT_DIR}"
RUNTIME_DIR="${ROOTFS}/usr/local/libexec/gvisor-i915/${GVISOR_COMMIT}"
CRI_DIR="${ROOTFS}/etc/cri/conf.d"
install -d -m 0755 "${RUNTIME_DIR}" "${CRI_DIR}"
install -m 0755 "${EXTRACT_DIR}/runsc" "${RUNTIME_DIR}/runsc-i915"
install -d -m 0755 "${RUNTIME_DIR}/gvisor-bin"
cp -a "${EXTRACT_DIR}/gvisor-bin/." "${RUNTIME_DIR}/gvisor-bin/"
find "${RUNTIME_DIR}/gvisor-bin" -type f -exec chmod 0755 {} +
test -x "${RUNTIME_DIR}/gvisor-bin/gvisor_sentry"

for sidecar in \
  gvisor_sentry \
  checkpointgofer \
  runsc-metric-server \
  runsc-fd-parking \
  gvisor-sentry-prewarmer \
  gvisor-proc-umounter; do
  test -x "${RUNTIME_DIR}/gvisor-bin/${sidecar}" || {
    printf 'ERROR: expected gVisor release sidecar missing: %s\n' "${sidecar}" >&2
    exit 1
  }
done

sed \
  -e "s/{{GVISOR_COMMIT}}/${GVISOR_COMMIT}/g" \
  "${ROOT_DIR}/hack/gvisor-i915/runsc-i915.toml.tmpl" > "${CRI_DIR}/runsc-i915.toml"
install -m 0644 "${ROOT_DIR}/hack/gvisor-i915/30-gvisor-i915.part" "${CRI_DIR}/30-gvisor-i915.part"

sed \
  -e "s/{{GVISOR_REV_SHORT}}/${GVISOR_REV_SHORT}/g" \
  "${ROOT_DIR}/hack/gvisor-i915/manifest.yaml.tmpl" > "${EXT_CONTEXT}/manifest.yaml"
cp "${ROOT_DIR}/hack/gvisor-i915/Containerfile" "${EXT_CONTEXT}/Containerfile"

EXTENSION_IMAGE="${EXTENSION_REPOSITORY}:${REGISTRY_TAG}"
printf '\n==> Build and publish system extension %s\n' "${EXTENSION_IMAGE}"
podman build \
  --platform linux/amd64 \
  --format oci \
  --build-arg "GVISOR_REV=${GVISOR_COMMIT}" \
  --tag "${EXTENSION_IMAGE}" \
  --file "${EXT_CONTEXT}/Containerfile" \
  "${EXT_CONTEXT}"
EXT_DIGEST_FILE="${OUT_DIR}/gvisor-i915-extension-${PROFILE}.digest"
podman push --digestfile "${EXT_DIGEST_FILE}" "${EXTENSION_IMAGE}"
EXT_DIGEST="$(tr -d '\r\n' < "${EXT_DIGEST_FILE}")"
[[ "${EXT_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  printf 'ERROR: Podman returned an invalid extension digest: %s\n' "${EXT_DIGEST}" >&2
  exit 1
}
EXTENSION_IMAGE_REF="${EXTENSION_IMAGE}@${EXT_DIGEST}"

printf '\n==> Build Talos installer with pinned base installer + custom extension\n'
podman run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "${IMAGER_OUT}:/out:rw" \
  --volume "${AUTH_FILE}:/run/registry-auth/config.json:ro,z" \
  --env DOCKER_CONFIG=/run/registry-auth \
  "${TALOS_IMAGER_IMAGE}" \
  installer \
  --arch amd64 \
  --base-installer-image "${BASE_INSTALLER_IMAGE}" \
  --system-extension-image "${EXTENSION_IMAGE_REF}" \
  --output /out

INSTALLER_TAR="${IMAGER_OUT}/installer-amd64.tar"
test -s "${INSTALLER_TAR}" || {
  printf 'ERROR: Talos imager did not produce %s\n' "${INSTALLER_TAR}" >&2
  find "${IMAGER_OUT}" -maxdepth 2 -type f -print >&2
  exit 1
}

printf '\n==> Load and publish commit-specific Talos installer\n'
LOAD_OUTPUT="$(podman load --input "${INSTALLER_TAR}")"
LOADED_IMAGE="$(printf '%s\n' "${LOAD_OUTPUT}" | sed -nE 's/^Loaded image(s)?:[[:space:]]*//p' | tail -n 1)"
if [[ -z "${LOADED_IMAGE}" ]]; then
  printf 'ERROR: could not determine loaded installer image reference. Podman output:\n%s\n' "${LOAD_OUTPUT}" >&2
  exit 1
fi

FINAL_INSTALLER_IMAGE="${INSTALLER_REPOSITORY}:${INSTALLER_TAG}"
podman tag "${LOADED_IMAGE}" "${FINAL_INSTALLER_IMAGE}"
INSTALLER_DIGEST_FILE="${OUT_DIR}/talos-installer-${PROFILE}.digest"
podman push --digestfile "${INSTALLER_DIGEST_FILE}" "${FINAL_INSTALLER_IMAGE}"
INSTALLER_DIGEST="$(tr -d '\r\n' < "${INSTALLER_DIGEST_FILE}")"
[[ "${INSTALLER_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  printf 'ERROR: Podman returned an invalid installer digest: %s\n' "${INSTALLER_DIGEST}" >&2
  exit 1
}

printf '%s\n' "${FINAL_INSTALLER_IMAGE}@${INSTALLER_DIGEST}" > "${OUT_DIR}/talos-installer-image-${PROFILE}.ref"
printf '%s\n' "${EXTENSION_IMAGE_REF}" > "${OUT_DIR}/gvisor-i915-extension-image-${PROFILE}.ref"

printf '\nBuild complete.\n'
printf 'Extension image: %s\n' "${EXTENSION_IMAGE_REF}"
printf 'Talos installer: %s\n' "${FINAL_INSTALLER_IMAGE}@${INSTALLER_DIGEST}"
printf '\nThe talconfig.yaml talosImageURL must use this repository path (Talhelper appends :%s):\n' "${TALOS_VERSION}"
printf '  %s\n' "${INSTALLER_REPOSITORY}"
printf '\nDigest reference file: %s\n' "${OUT_DIR}/talos-installer-image-${PROFILE}.ref"
printf 'Extension digest reference file: %s\n' "${OUT_DIR}/gvisor-i915-extension-image-${PROFILE}.ref"
printf 'gVisor release archive: %s\n' "${OUT_DIR}/${ARCHIVE_ARTIFACT}"
printf 'Use this profile-specific digest for talosctl upgrade --image.\n'
