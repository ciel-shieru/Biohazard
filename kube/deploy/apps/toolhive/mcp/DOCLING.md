# Docling via ToolHive and LLMKube

## Architecture

- `MCPServer/mcp/docling` is a non-root gVisor-isolated, streamable-HTTP
  Docling MCP endpoint in *remote* mode. The existing `MCPGroup/mcp` and
  `VirtualMCPServer/mcp` discover it; no new ingress route is added.
- `InferenceService/llmkube/docling-serve` runs the official **CUDA 12.8
  Docling Serve 1.38.2** image on **sinon**, requesting **one T4**. Its
  image already contains Docling's specialized PDF-layout, TableFormer,
  and OCR model assets. These stages run in Docling, not in an OpenAI
  chat-completions server. LLMKube operates the overall inference service.
- LLMKube's generic-runtime API requires `modelRef` even when models
  are image-bundled. `Model/docling-bundled-models` uses the pre-existing
  Bound `llmkube-models` PVC as an identity/reference, **not** as the source
  of its executable weights. `skipModelInit: true` avoids model staging;
  the real layout/table/OCR weights are pinned by the serving OCI image.
- Docling's admin-controlled `auto-vision` picture-description preset
  calls `http://llmkube.llmkube.svc.cluster.local/v1/chat/completions`
  with `model: auto-vision` and **no API key or Authorization header**.
  Upstream LLMKube already supplies this router alias.
- Cilium restricts MCP-to-Serve to TCP/5001 and Serve-to-router to
  TCP/8080. The source PDFs and derived images never need cloud APIs.
  The backend does not have general Internet egress.

The CUDA 12.8 serving image is pinned to its upstream GHCR v1.38.2
manifest digest; the CPU-only MCP image uses its independently published
Quay.io v1.38.2 digest. The CPU MCP image bundles Docling MCP v3.3.0, despite the separately
released `docling-mcp` v3.5.0; this avoids unpinned runtime pip installs.

## Visual fidelity and limitations

`DOCLING_MCP_KEEP_IMAGES=true`, scale `2.0`, and Markdown image
`embedded` preserve page/picture raster data *in the export*, alongside
layout structure, OCR, tables and optional picture descriptions. Embedded
base64 images may be very large: avoid blindly putting complete long-PDF
exports into an LLM context. Use Docling JSON plus targeted page images or
the original PDF where exact pixel-level fidelity is required.

No extraction is guaranteed to preserve **all** visual information or to
transcribe every graph/diagram correctly. Picture descriptions depend on
the selected `auto-vision` backend. Docling's optional formula enrichment
and chart-to-data extraction are **not automatically enabled** by these
MCP configuration flags; clients requiring them should use validated
Docling Serve conversion options separately.

MCP tools need a document they can access by their supported URI. Chat
attachments are not automatically mounted into the MCP pod. In particular,
the network policy deliberately prevents the backend from downloading
arbitrary public URLs: first make the input available through a trusted
in-cluster upload/URL workflow and allow only its specific network peer.
Do not bypass the SSRF and exfiltration restrictions with wildcard egress.

## Single-T4 sharing and memory budget

The existing NVIDIA GPU Operator
(`kube/deploy/core/hardware/nvidia/app/time-slicing.yaml`) sets
`sharing.timeSlicing.resources[0].replicas: 8` for `nvidia.com/gpu`.
Consequently, all three independent `nvidia.com/gpu: 1` pods can
schedule onto **the same physical Tesla T4** without a ModelPool.
This is time slicing, not MIG, partitioning or VRAM isolation. Every
replica sees the full card, can allocate all its memory, and contends
for compute and memory bandwidth. Eight advertised resources do not
mean eight independent 16 GiB memory allocations.

The embedding and reranker currently use **2,595 MiB of 16,384 MiB**.
That leaves approximately **13,789 MiB** available before other runtime,
CUDA, model-loading and fragmentation overhead. Measure Docling peak
VRAM (including page batching, TableFormer and OCR execution) before
assuming it can coexist under bursty workloads; keep conservative
one-worker, one-page batch defaults initially. If necessary, reduce
batching further or move stages to CPU without making unrelated
embedding/reranker service changes.

The former two-GPU `Model.spec.hardware.gpu.count` declarations of
the embedding/reranker are corrected to one for the updated node
inventory. Their existing InferenceService GPU request remains one.
There is no requirement to move either to CPU merely for scheduling.

The Docling runtime is **not** in gVisor: GPU passthrough is required.
The MCP pod uses gVisor and restricted Pod Security controls. Both drop
all capabilities and run non-root with a read-only root filesystem.

## Validation

1. `flux build ks toolhive-mcp --path ./kube/deploy/apps/toolhive/mcp`
   and `flux build ks llmkube-models --path ./kube/deploy/apps/llmkube/models`;
   alternatively validate with `kubectl apply --dry-run=server -f` for
   each new manifest after Flux substitution.
2. `kubectl -n llmkube get model docling-bundled-models`,
   `kubectl -n llmkube get inferenceservice docling-serve`, and
   `kubectl -n mcp get mcpserver docling`; check Cilium policy status.
3. Verify `docling-serve` serves `GET /ready` and the MCP proxy lists
   its tools via the existing VirtualMCPServer. Confirm CUDA device 0
   maps to the **single Tesla T4**.
4. Convert a trusted, multi-page PDF with selectable text, a scanned
   page, a multi-row table, and a chart. Compare Docling JSON text/table
   positions with the source. Confirm image content is returned, not
   `<!-- image -->` placeholders, and descriptions use `auto-vision`.
5. Test malformed, oversized, password-protected and highly compressed
   PDFs, a failed VLM backend, and a blocked external URI; verify no
   untrusted destination or metadata endpoint is reachable.
6. Check memory/VRAM usage, 7,200-second timeout behavior and the actual
   MCP/Docling image UID with the restricted Pod Security and gVisor
   constraints. An in-cluster smoke test is required before production.
