# OpenClaw local code intelligence

Adds Code-Graph-RAG as a separate workload in the OpenClaw namespace for the
Qwen Code and OpenCode agents sharing the `openclaw-data` workspace PVC.

## Components

- **Code-Graph-RAG v0.5.3 (MIT)**: Tree-sitter parsing, embedded SQLite
  knowledge graph, structural/call navigation, semantic retrieval, and a
  read-only Streamable HTTP MCP server.
- **SQLite-vec**: local vectors on a dedicated PVC; embeddings come from the
  configured local Qwen3 embedding endpoint.
- **Qwen3-Reranker-0.6B**: separate MCP tool to rerank retrieved snippets,
  returning IDs, paths, and scores.
- **Qwen 3.6 35B A3B**: configured local orchestrator/Cypher model.

No runtime model weights are downloaded. The service has no Internet egress,
LoadBalancer, or HTTPRoute. Only OpenClaw can reach its MCP Service. Inference
egress is restricted to internal `llama-cpp`/`llmkube` namespaces and the
`sinon`/`silverhawk` nodes on TCP 8080, plus cluster DNS.

## Isolation and storage

- `openclaw-data` is mounted read-only at `/workspace`; Pod affinity keeps
  both RWO-PVC consumers on the same node.
- A dedicated 20Gi `block-2` RWO PVC, `openclaw-code-intel`, stores graph,
  vectors, and incremental-index state. It is regenerable and not backed up.
- Processes run as UID/GID 1000 under gVisor, with read-only root filesystems,
  all capabilities dropped, no privilege escalation, and RuntimeDefault seccomp.
- The Pod has no Kubernetes service-account token and no GitHub/Internet egress.
- Graph MCP is bearer-token authenticated and read-only. Reranker ingress is
  limited by Cilium policy to the OpenClaw agent Pod.
- The platform `.cgrignore` excludes environment files, common credentials,
  keys, kubeconfigs, and Terraform state. This is filename filtering, not a
  secret scanner; embedded secrets in ordinary source still need to be removed
  or explicitly excluded.

## One-time 1Password configuration

Create a Secure Note named **OpenClaw Code Intelligence - biohazard** (or the
cluster-suffixed item required by Flux) with:

- `MCP_HTTP_AUTH_TOKEN`: a fresh high-entropy token (e.g.
  `openssl rand -hex 32`).
- `LLM_API_BASE_URL`: the local OpenAI-compatible model-router base URL,
  including `/v1`, e.g. your local LLMKube router. Do not use a public URL.

ExternalSecrets projects those values into `openclaw-code-intel-secrets`.
Ensure these local model aliases exist on that router:

- `qwen3.6-35b-a3b` for orchestration/Cypher.
- `qwen3-embedding-0.6b` for embeddings (native 1,024 dimensions).
- `qwen3-reranker-0.6b` for reranking.

The Qwen init container writes user-level MCP settings idempotently and waits
for the ExternalSecret to create its Secret before proceeding.

## MCP endpoints

- Graph, structural, and semantic retrieval:
  `http://openclaw-code-intel-mcp.openclaw.svc.cluster.local:8787/mcp`
- Candidate reranking:
  `http://openclaw-code-intel-mcp.openclaw.svc.cluster.local:8788/mcp`

OpenCode loads `OPENCODE_CONFIG_CONTENT` from the ConfigMap. Qwen Code
registers both endpoints in its persistent user MCP settings. Invoke the
reranker after retrieval when candidate ordering matters.

## Index scope

The watcher indexes the complete Qwen Code workspace as one aggregate root.
It reads the root `.gitignore` and platform `.cgrignore`, not nested
repositories' individual ignore files in aggregate-root mode. Code-Graph-RAG
defaults also exclude `.git` metadata and common generated directories.

## Build and validation

The image workflow checks out Code-Graph-RAG at immutable commit
`22444ca64a6d0b246f00996f47ec376f32267264`, builds linux/amd64 and linux/arm64 using pinned base
images/lockfiles, installs Tree-sitter grammars and only the `sqlite-vec`
extra, emits an SBOM/provenance attestation, and commits the OCI digest back
into the HelmRelease. Runtime model downloads are not performed.

Upstream v0.5.3 is marked Beta. This integration still requires image-build,
Flux manifest, and in-cluster smoke/performance validation before it should
be treated as production-ready.
