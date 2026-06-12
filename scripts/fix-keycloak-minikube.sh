#!/usr/bin/env bash
#
# Keycloak workaround for a minikube DEV cluster running on an EMULATED x86_64 VM
# (e.g. an amd64 OrbStack/UTM guest on an Apple Silicon / arm64 Mac).
#
# Root cause
# ----------
# Under x86 emulation the Keycloak JVM cannot reliably run JIT-compiled code:
#   - JIT enabled       -> SIGILL  (emulated AVX instructions the layer can't run)
#   - -XX:UseAVX=0      -> SIGSEGV (crash inside C1-compiled code)
# The only stable mode is fully *interpreted* execution: JAVA_TOOL_OPTIONS=-Xint.
# That is correct but SLOW, which breaks two things the operator can't cope with:
#
#   1. Boot time. `kc.sh start` does a Quarkus build + start on every boot. Under
#      -Xint that takes well over the Keycloak operator's hard-coded startup probe
#      budget (~600 s, periodSeconds:1 / timeoutSeconds:1), so the kubelet keeps
#      killing the pod mid-boot -> CrashLoopBackOff. The operator OWNS the probes
#      (it ignores probe overrides in the CR podTemplate), so the only way to make
#      them patient is to scale the operator down and patch the StatefulSet directly.
#
#   2. Realm import. Creating a realm generates several RSA keypairs
#      (DefaultKeyProviders -> BouncyCastle RSAKeyPairGenerator -> BigInteger.modPow).
#      Under -Xint this is so slow that the Narayana JTA transaction reaper
#      (ARJUNA012117) aborts the transaction -> HTTP 400 "Database operation failed"
#      -> the realm is never persisted. Fix: raise the transaction timeout
#      (QUARKUS_TRANSACTION_MANAGER_DEFAULT_TRANSACTION_TIMEOUT). The operator's own
#      KeycloakRealmImport Job is a separate JVM that crashes the same way, so we
#      import via the Admin REST API instead (and bypass the nginx 60s ingress
#      timeout with a port-forward).
#
# A separate, GENERAL bug is fixed in the chart (naavre/templates/keycloak.yaml),
# not here: http-management-relative-path=/ keeps the health endpoints at
# /health/ready so the operator probe (which targets /health/ready) is not 404ed
# by http-relative-path=/auth.
#
# Run this AFTER `./deploy.sh ... upgrade --install`. It is idempotent and must be
# re-run after every `helm upgrade` (the upgrade recreates the operator-managed
# StatefulSet / CR with the default fast probes).
#
# NOTE: DEV-only workaround for CPU emulation. A native amd64 host (real Intel/AMD
# machine or cloud VM) runs Keycloak normally and needs NONE of this.
set -euo pipefail

NS="${1:-new-naavre}"
DOMAIN="${2:-naavre-dev.minikube.test}"
KC="naavre-keycloak"
BASE_PATH="${KC_BASE_PATH:-auth}"
TXN_TIMEOUT="${KC_TXN_TIMEOUT:-3600}"

echo "=== 1. Scale the Keycloak operator down (stop it enforcing fast probes) ==="
# The operator created the StatefulSet during `helm upgrade`; from now on we manage
# it directly. With the operator running it would revert the patient probes below.
kubectl -n "$NS" scale deploy keycloak-operator --replicas=0
sleep 3

echo "=== 2. Patch the StatefulSet: -Xint + long txn timeout + patient probes ==="
# env is a list keyed by name, so strategic-merge ADDS these without dropping others.
cat > /tmp/kc-sts-patch.json <<EOF
{"spec":{"template":{"spec":{"containers":[{"name":"keycloak",
  "env":[
    {"name":"JAVA_TOOL_OPTIONS","value":"-Xint"},
    {"name":"QUARKUS_TRANSACTION_MANAGER_DEFAULT_TRANSACTION_TIMEOUT","value":"${TXN_TIMEOUT}"},
    {"name":"QUARKUS_DATASOURCE_JDBC_ACQUISITION_TIMEOUT","value":"600S"}
  ],
  "startupProbe":{"httpGet":{"path":"/health/started","port":9000,"scheme":"HTTPS"},"initialDelaySeconds":30,"periodSeconds":15,"timeoutSeconds":10,"failureThreshold":200,"successThreshold":1},
  "livenessProbe":{"httpGet":{"path":"/health/live","port":9000,"scheme":"HTTPS"},"periodSeconds":30,"timeoutSeconds":10,"failureThreshold":12,"successThreshold":1},
  "readinessProbe":{"httpGet":{"path":"/health/ready","port":9000,"scheme":"HTTPS"},"periodSeconds":15,"timeoutSeconds":10,"failureThreshold":12,"successThreshold":1}
}]}}}}
EOF
kubectl -n "$NS" patch statefulset "$KC" --type=strategic --patch-file /tmp/kc-sts-patch.json
kubectl -n "$NS" delete pod "${KC}-0" --ignore-not-found --force --grace-period=0 2>/dev/null || true

echo "=== 3. Wait for Keycloak ready (interpreted boot, up to ~25 min) ==="
ready=false
for i in $(seq 1 100); do
  sleep 15
  ready=$(kubectl -n "$NS" get pod "${KC}-0" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  rc=$(kubectl -n "$NS" get pod "${KC}-0" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
  echo "  t=$((i * 15))s ready=$ready restarts=$rc"
  [ "$ready" = "true" ] && break
done
if [ "$ready" != "true" ]; then
  echo "Keycloak did not become ready — last logs:"
  kubectl -n "$NS" logs "${KC}-0" --tail=40 || true
  exit 1
fi

echo "=== 4. Capture realm spec from the deployed Helm manifest ==="
# Source of truth = the rendered chart (fully resolved secrets/users), so this works
# even though the crashing operator KeycloakRealmImport Job has been removed.
helm -n "$NS" get manifest naavre > /tmp/naavre-manifest.yaml
REALM_JSON=$(python3 - <<'PY'
import json, yaml
realm = None
for d in yaml.safe_load_all(open('/tmp/naavre-manifest.yaml').read()):
    if d and d.get('kind') == 'KeycloakRealmImport':
        realm = d['spec']['realm']
        realm['realm'] = 'vre'; realm['enabled'] = True
        break
print(json.dumps(realm) if realm else '')
PY
)
[ -n "$REALM_JSON" ] || { echo "Could not extract realm spec from manifest"; exit 1; }
# Remove the operator's crashing KeycloakRealmImport (no-op if already gone).
kubectl -n "$NS" delete keycloakrealmimport "${KC}-realm-import" --ignore-not-found

echo "=== 5. Import realm vre via Admin REST API (port-forward bypasses nginx) ==="
kubectl -n "$NS" port-forward "pod/${KC}-0" 18443:8443 >/tmp/kc-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 6
BASE="https://localhost:18443/$(echo "$BASE_PATH" | tr -d '/')"

ADMIN_USER=$(kubectl -n "$NS" get secret "${KC}-admin" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl -n "$NS" get secret "${KC}-admin" -o jsonpath='{.data.password}' | base64 -d)

TOKEN=$(curl -sk --max-time 180 -X POST "${BASE}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=${ADMIN_USER}" \
  --data-urlencode "password=${ADMIN_PASS}" | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to obtain admin token"; cat /tmp/kc-pf.log; exit 1
fi

if curl -sk --max-time 60 -H "Authorization: Bearer $TOKEN" "${BASE}/admin/realms/vre" \
    | jq -e '.realm == "vre"' >/dev/null 2>&1; then
  echo "  realm vre already exists"
else
  # --max-time 900: the realm POST blocks on slow interpreted RSA keygen.
  CODE=$(curl -sk --max-time 900 -w '%{http_code}' -o /tmp/realm-resp.json \
    -X POST "${BASE}/admin/realms" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$REALM_JSON")
  echo "  realm import HTTP $CODE"
  if [ "$CODE" != "201" ] && [ "$CODE" != "409" ]; then cat /tmp/realm-resp.json; echo; exit 1; fi
fi

echo "=== 5b. Ensure OIDC client 'naavre' is confidential (NextAuth sends client_secret) ==="
CLIENT_UUID=$(curl -sk --max-time 60 -H "Authorization: Bearer $TOKEN" \
  "${BASE}/admin/realms/vre/clients?clientId=naavre" | jq -r '.[0].id // empty')
if [ -z "$CLIENT_UUID" ]; then
  echo "  WARN: client 'naavre' not found in realm vre"
else
  CLIENT_JSON=$(curl -sk --max-time 60 -H "Authorization: Bearer $TOKEN" \
    "${BASE}/admin/realms/vre/clients/${CLIENT_UUID}")
  NAAVRE_SECRET=$(echo "$REALM_JSON" | jq -r '.clients[] | select(.clientId=="naavre") | .secret // empty')
  UPDATED=$(echo "$CLIENT_JSON" | jq --arg s "$NAAVRE_SECRET" '
    .publicClient = false
    | .clientAuthenticatorType = "client-secret"
    | if ($s | length) > 0 then .secret = $s else . end
  ')
  CODE=$(curl -sk --max-time 60 -w '%{http_code}' -o /tmp/kc-client-resp.json \
    -X PUT "${BASE}/admin/realms/vre/clients/${CLIENT_UUID}" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$UPDATED")
  echo "  client naavre patch HTTP $CODE (publicClient=false)"
fi

echo "  realm issuer:"
curl -sk --max-time 60 "${BASE}/realms/vre/.well-known/openid-configuration" | jq -r '.issuer // .error'
kill $PF 2>/dev/null || true
trap - EXIT

echo "=== 6. Restart argo-server (needs realm vre for OIDC discovery) ==="
kubectl -n "$NS" rollout restart deployment/naavre-naavre-argo-server
kubectl -n "$NS" rollout status deployment/naavre-naavre-argo-server --timeout=300s || true

echo "=== Done — cluster state ==="
kubectl -n "$NS" get pods
