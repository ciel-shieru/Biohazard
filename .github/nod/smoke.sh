#!/usr/bin/env bash
set -euo pipefail
network="nod-smoke-${GITHUB_RUN_ID:-local}"
cleanup() {
  docker logs nod-smoke-server 2>&1 || true
  docker rm -f nod-smoke-server nod-smoke-db nod-smoke-model >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create --internal "$network" >/dev/null
docker run -d --name nod-smoke-db --network "$network" --network-alias postgres \
  -e POSTGRES_USER=nod -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=nod \
  postgres:17.12-alpine@sha256:526f86d93c6ea08fd3f1fe5605650cacc781b2c6013169a0ad8f42c7d3d84f32 >/dev/null
docker run -d --name nod-smoke-model --network "$network" --network-alias model \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -v "$PWD/.github/nod/model-fixture.mjs:/fixture.mjs:ro" \
  node:24.22.3-bookworm-slim@sha256:dc26ae92c9fb15cf6b1d63e20f0944b2efe0f115b20e00be48fb23fceb061c54 node /fixture.mjs >/dev/null
for _ in {1..60}; do
  if docker exec nod-smoke-db pg_isready -h 127.0.0.1 -U nod -d nod >/dev/null 2>&1; then break; fi
  sleep 1
done
docker run -d --name nod-smoke-server --network "$network" --read-only --cap-drop ALL \
  --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --tmpfs /var/lib/nod:rw,nosuid,uid=1000,gid=1000,mode=700,size=256m \
  -e NOD_PUBLIC_URL=http://localhost:4310 \
  -e NOD_AUTH_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  -e NOD_VAULT_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
  -e DATABASE_URL=postgresql://nod:smoke@postgres:5432/nod \
  -e LLM_PROVIDER=compatible -e LLM_MODEL=fixture-model \
  -e OPENAI_COMPATIBLE_BASE_URL=http://model:8080/v1 -e NOD_TRUST_MODEL=selected \
  -e NOD_ANALYTICS_ENABLED=false -e NOD_FEEDBACK_ENABLED=false -e NOD_FEEDBACK_URL= \
  -e NOD_ONBOARDING_EMAIL_URL= -e NOD_TRACES_URL= -e OTEL_EXPORTER_OTLP_ENDPOINT= \
  -e TELEGRAM_ENABLED=false -e WHATSAPP_ENABLED=false nod-test:local >/dev/null
server_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nod-smoke-server)
base_url="http://${server_ip}:4310"
auth='Authorization: Bearer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
host='Host: localhost:4310'
for _ in {1..120}; do
  if curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" "$base_url"/api/health >/dev/null; then break; fi
  sleep 1
done
curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" "$base_url"/api/health | jq -e '.ok == true' >/dev/null
curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" "$base_url"/api/session >/dev/null
curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" -H 'Content-Type: application/json' -d '{}' "$base_url"/api/account/prepare >/dev/null
curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" -H 'Content-Type: application/json' -d '{}' "$base_url"/api/account/model-setup >/dev/null
curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -X PATCH -H "$host" -H "$auth" -H 'Content-Type: application/json' -d '{"onboardingCompleted":true}' "$base_url"/api/account >/dev/null
turn_id=$(curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" -H 'Content-Type: application/json' -d '{"text":"Say hello."}' "$base_url"/api/messages | jq -er '.turnId | select(type == "string" and length > 0)')
for _ in {1..120}; do
  if curl --connect-timeout 3 --max-time 10 --noproxy "*" -fsS -H "$host" -H "$auth" "$base_url"/api/messages | jq -e --arg turn "$turn_id" '.messages[] | select(.turnId == $turn and .role == "assistant" and (.text | contains("fixture reply")))' >/dev/null; then
    exit 0
  fi
  sleep 1
done
printf '%s\n' 'No fixture reply appeared in message history' >&2
exit 1
