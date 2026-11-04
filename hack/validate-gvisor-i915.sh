#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${BUNDLE_DIR}/apply.sh" ]]; then
  bash -n "${BUNDLE_DIR}/apply.sh"
fi
bash -n "${BUNDLE_DIR}/hack/build-gvisor-i915-installer.sh"

python3 - "${BUNDLE_DIR}" <<'PY'
from pathlib import Path
import re
import sys
import tomllib

root = Path(sys.argv[1])

toml_template = (root / "hack/gvisor-i915/runsc-i915.toml.tmpl").read_text()
fragment = (root / "hack/gvisor-i915/30-gvisor-i915.part").read_text()
manifest = (root / "hack/gvisor-i915/manifest.yaml.tmpl").read_text()

build_script = (root / "hack/build-gvisor-i915-installer.sh").read_text()
match = re.search(r'^readonly GVISOR_COMMIT="([0-9a-f]{40})"$', build_script, re.MULTILINE)
assert match, "build script must pin exactly one 40-character gVisor commit"
commit = match.group(1)
short = commit[:12]
rendered_toml = toml_template.replace("{{GVISOR_COMMIT}}", commit)
config = tomllib.loads(rendered_toml)
assert config["binary_name"] == f"/usr/local/libexec/gvisor-i915/{commit}/runsc-i915"
assert config["runsc_config"] == {"i915proxy": "true"}

# Validate the CRI handler and its ConfigPath as TOML.
cri = tomllib.loads(fragment)
runtime = cri["plugins"]["io.containerd.cri.v1.runtime"]["containerd"]["runtimes"]["runsc-i915"]
assert runtime["runtime_type"] == "io.containerd.runsc.v1"
assert runtime["options"]["TypeUrl"] == "io.containerd.runsc.v1.options"
assert runtime["options"]["ConfigPath"] == "/etc/cri/conf.d/runsc-i915.toml"

rendered_manifest = manifest.replace("{{GVISOR_REV_SHORT}}", short)
assert f"0.1.0+{short}" in rendered_manifest
assert 'version: ">= v1.13.0"' in rendered_manifest

runtime_class = (root / "kube/clusters/biohazard/config/gvisor-i915.yaml").read_text()
assert "name: gvisor-i915" in runtime_class
assert "handler: runsc-i915" in runtime_class
assert 'gvisor-i915.home.arpa/enabled: "true"' in runtime_class

pod_path = root / "examples/i915-smoke-pod.yaml"
if not pod_path.exists():
    pod_path = root / "hack/gvisor-i915/i915-smoke-pod.yaml"
pod = pod_path.read_text()
assert "runtimeClassName: gvisor-i915" in pod
assert "gpu.intel.com/i915: 1" in pod
assert "allowPrivilegeEscalation: false" in pod
assert 'drop: ["ALL"]' in pod
assert "automountServiceAccountToken: false" in pod

# The script lives in hack/ inside the repository; validate its integration points too.
config_dir = root / "kube/clusters/biohazard/config"
talconfig_path = root / "kube/clusters/biohazard/talos/talconfig.yaml"
taskfile_path = root / ".taskfiles/talos/Taskfile.dist.yaml"
if config_dir.exists() and talconfig_path.exists() and taskfile_path.exists():
    kustomization = (config_dir / "kustomization.yaml").read_text()
    talconfig = talconfig_path.read_text()
    taskfile = taskfile_path.read_text()
    assert "- ./gvisor-i915.yaml" in kustomization
    assert f"ghcr.io/jjgadgets/talos-installer-gvisor-i915-m720q-{commit}" in talconfig
    assert f"ghcr.io/jjgadgets/talos-installer-gvisor-i915-ms01-{commit}" in talconfig
    assert talconfig.count('gvisor-i915.home.arpa/enabled: "true"') == 2
    assert "IMAGE: '{{ or .IMAGE \"\" }}'" in taskfile
    assert "INSTALLER_IMAGE: '{{.IMAGE}}'" in taskfile
    assert ' --image "${INSTALLER_IMAGE}"' in taskfile

print("gvisor-i915 validation passed (shell syntax, CRI/shim TOML, extension manifest, RuntimeClass, smoke Pod and repository wiring when run in Biohazard).")
PY
