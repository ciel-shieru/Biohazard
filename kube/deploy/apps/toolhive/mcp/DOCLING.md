# Docling via ToolHive and LLMKube

## Architecture and native VLM integration

- `MCPServer/mcp/docling` runs the **stock upstream** `docling-mcp-server`
  in remote conversion mode, without custom Python code or extra tools.
  The existing `MCPGroup/mcp` / `VirtualMCPServer/mcp` discover it.
- `InferenceService/llmkube/docling-serve` runs Docling Serve v1.38.2
  with local layout, TableFormer, OCR and PDF rendering on `sinon` using
  one time-sliced Tesla T4 resource. The official CUDA 12.8 image includes
  specialized model weights; `skipModelInit: true` avoids staging.
  The generic-runtime `Model/docling-bundled-models` provides the required
  ModelRef identity using the existing Bound `llmkube-models` PVC.
- Docling MCP uses `DOCLING_MCP_DO_PICTURE_DESCRIPTION=true` and
  `DOCLING_MCP_PICTURE_DESCRIPTION_PRESET=auto-vision`, sending both
  options through its supported remote conversion API.
- Docling Serve's administrator-defined `auto-vision` picture-description
  preset uses the built-in `api` VLM engine, OpenAI-compatible
  `http://llmkube.llmkube.svc.cluster.local/v1/chat/completions`,
  `model: auto-vision`, and **no API key or Authorization header**.
  `DOCLING_SERVE_ENABLE_REMOTE_SERVICES=true` enables this functionality.
  `DOCLING_SERVE_ALLOW_CUSTOM_PICTURE_DESCRIPTION_CONFIG=false` and
  allowlists for the preset and API engine disallow client-supplied endpoints.

## Network and security boundaries

- ToolHive MCP may egress to Docling Serve on TCP/5001 and to kube-dns
  under the existing clusterwide DNS policy. It has **no** direct router
  egress and no world/host egress.
- Docling Serve may egress to the llmkube router pod on TCP/8080 and to
  kube-dns under the clusterwide DNS policy. It carries the
  `ai.internal/llmkube: allow` label required by the router ingress policy,
  but does **not** receive general Internet access.
- The dedicated Cilium policy permits MCP-to-Serve inbound conversion
  on TCP/5001, subject to the existing shared LLMKube policy.
  A deny-all egress rule cannot coexist with permitted router egress,
  because Cilium deny policies take precedence over allows.
- The cluster's Cilium allow policies are **additive**: audit the effective
  Cilium endpoint policy to confirm no unexpected clusterwide allows
  expand either workload's destinations. `HF_HUB_OFFLINE=1` and
  `TRANSFORMERS_OFFLINE=1` prevent opportunistic model downloads.
- MCP is nonroot, read-only root filesystem, seccomp, drop-all
  capabilities and gVisor isolated. Docling Serve uses the same
  least-privilege controls but not gVisor due to GPU access.

## Visual information preservation

`DOCLING_MCP_KEEP_IMAGES=true`, `DOCLING_MCP_IMAGES_SCALE=2.0` and
`DOCLING_MCP_IMAGE_EXPORT_MODE=embedded` retain page and picture images,
alongside structured layout, OCR, tables and native picture descriptions
in Docling conversion output. Embedded images can be large: use
targeted JSON extraction or selected page bitmaps for long PDFs.

Native picture description enriches **detected pictures**, not every
pixel of every page. The stock Docling MCP tool `get_page_thumbnail`
can provide a whole cached page for separate agent inspection; there
is no custom whole-page vision tool. The original PDF remains the
authoritative reference when pixel-level fidelity is required.
Formula enrichment and chart-to-data extraction are separate optional
features; they are not automatically enabled by these MCP flags.

Chat attachments are not automatically mounted in the MCP pod. It needs
a trusted in-cluster file/URL workflow; arbitrary Internet URI retrieval
is intentionally blocked. Never widen egress to world merely for
convenient document fetching.

## Shared Tesla T4

The NVIDIA GPU Operator advertises eight time-sliced `nvidia.com/gpu`
resources on the single physical T4. Docling, embedding and reranking
can each request one such resource. There is **no VRAM isolation**.
Embedding and reranker currently consume approximately 2,595 MiB of
16,384 MiB, leaving about 13,789 MiB before other allocations. Use
one Docling worker and one-page batching, monitor worst-case VRAM
under concurrent jobs, and do not assume 8x physical memory exists.
The embedding/reranking Model GPU counts have been aligned to one
for the current hardware inventory.

## Validation before merging

1. Validate the Flux Kustomizations and CRD schemas for LLMKube,
   ToolHive, Cilium and the new Docling manifests.
2. Confirm the **actual registry image digests** are valid, and the
   expected CUDA and CPU Docling image entrypoints exist. Static review
   cannot replace a runtime image-pull test.
3. Confirm `/ready`, `/health`, MCP tool discovery and startup
   preset validation. Assert the `auto-vision` preset is accepted with
   `default_repo_id`, `response_format=plaintext`, `engine_type=api`.
4. Convert a trusted multi-page PDF containing OCR scans, tables,
   charts, diagrams and small labels. Inspect Docling JSON,
   embedded page images and native descriptions. Verify calls to
   `auto-vision` originate from **Docling Serve** without API keys.
5. Observe Hubble: MCP → Serve TCP/5001 and Serve → router TCP/8080
   should pass. MCP → router, world/host egress from either workload
   and all other unauthorized flows should be denied. Verify shared
   DNS policy remains limited to kube-dns.
6. Test malicious PDFs, blocked URL input, failed VLM backend,
   timeouts, batch limits, RAM/VRAM pressure and image fidelity.

This PR remains **draft** until in-cluster verification succeeds.
