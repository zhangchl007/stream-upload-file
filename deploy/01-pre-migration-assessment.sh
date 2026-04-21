#!/bin/bash
# =============================================================================
# 01-pre-migration-assessment.sh
# Audit an AKS 1.24 cluster and produce a full migration readiness report.
# Run this BEFORE any migration actions; it is entirely read-only.
#
# Key design decisions:
#  - kubectl get pods/all -o yaml is NEVER used (causes hangs on large clusters)
#  - Pod-level checks use a single kubectl get pods -o json, processed by python3
#  - Deprecated API checks use kubectl api-versions (fast) + per-type queries
#  - All heavy fetches are done once and reused
# =============================================================================

# This script relies on Bash features such as [[ ]], arrays, process
# substitution, ERR traps, and pipefail. If it is launched via sh/dash,
# re-exec it with bash before any Bash-specific syntax runs.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: this script requires bash, but bash was not found in PATH." >&2
  exit 1
fi

# -u  : treat unbound variables as errors (catches typos)
# -o pipefail : pipeline exit code = last non-zero stage
# NO -e : we never exit on a failed command — collect as much as possible
set -uo pipefail

# Log any command failure but keep going
trap 'echo -e "\033[0;31m[FAIL]\033[0m  command failed at line $LINENO (exit $?) — continuing" | tee -a "${REPORT_FILE:-/dev/stderr}"' ERR

REPORT_DIR="assessment-$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="$REPORT_DIR/migration-report.txt"
DEPRECATED_APIS_FILE="$REPORT_DIR/deprecated-apis.txt"
PSP_FILE="$REPORT_DIR/pod-security-policies.yaml"
PVC_FILE="$REPORT_DIR/persistent-volume-claims.json"
STORAGE_FILE="$REPORT_DIR/storage-classes.json"
HELM_FILE="$REPORT_DIR/helm-releases.txt"
LB_FILE="$REPORT_DIR/loadbalancer-services.txt"
PODS_JSON="$REPORT_DIR/all-pods.json"
SUMMARY_FILE="$REPORT_DIR/SUMMARY.md"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
WARN_COUNT=0; ERROR_COUNT=0

mkdir -p "$REPORT_DIR"

warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"  | tee -a "$REPORT_FILE"; ((WARN_COUNT++))  || true; }
error()   { echo -e "${RED}[ERROR]${NC} $*"     | tee -a "$REPORT_FILE"; ((ERROR_COUNT++)) || true; }
info()    { echo -e "${BLUE}[INFO]${NC}  $*"    | tee -a "$REPORT_FILE"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"   | tee -a "$REPORT_FILE"; }
section() {
  echo ""                                                        | tee -a "$REPORT_FILE"
  echo "================================================================" | tee -a "$REPORT_FILE"
  echo "  $*"                                                    | tee -a "$REPORT_FILE"
  echo "================================================================" | tee -a "$REPORT_FILE"
}

# =============================================================================
section "PREREQUISITE CHECK"
# =============================================================================

for cmd in kubectl python3 jq; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd found: $(command -v "$cmd")"
  else
    error "$cmd not found — install it before continuing"
  fi
done

if command -v helm &>/dev/null; then
  ok "helm found: $(helm version --short 2>/dev/null || echo 'unknown')"
  HAVE_HELM=true
else
  warn "helm not found — Helm release checks will be skipped"
  HAVE_HELM=false
fi

if command -v pluto &>/dev/null; then
  ok "pluto found: $(pluto version 2>&1 | head -1)"
  HAVE_PLUTO=true
else
  warn "pluto not found — deprecated API scan will use kubectl fallback"
  warn "Install: https://github.com/FairwindsOps/pluto/releases"
  HAVE_PLUTO=false
fi

# =============================================================================
section "CLUSTER INFO"
# =============================================================================

CURRENT_CTX=$(kubectl config current-context)
info "kubectl context : $CURRENT_CTX"

SERVER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion')
info "Server version  : $SERVER_VERSION"

MINOR=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.minor' | tr -d '+')
MAJOR=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.major')
if [[ "$MAJOR" -eq 1 && "$MINOR" -lt 25 ]]; then
  ok "Server is on 1.${MINOR} — confirmed pre-1.25 (upgrade candidate)"
else
  warn "Server version is 1.${MINOR} — expected <= 1.24"
fi

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
info "Total nodes     : $NODE_COUNT"
kubectl get nodes -o wide 2>&1 | tee -a "$REPORT_FILE"

# Node resource capacity, allocatable, taints, labels
info "Node capacity and allocatable resources:"
kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for n in d.get('items', []):
    name = n['metadata']['name']
    cap  = n.get('status', {}).get('capacity', {})
    alloc = n.get('status', {}).get('allocatable', {})
    taints = n.get('spec', {}).get('taints', [])
    labels = {k: v for k, v in n['metadata'].get('labels', {}).items()
              if k.startswith('agentpool') or k.startswith('nodepool') or
                 k.startswith('kubernetes.io/') or k.startswith('node.kubernetes.io/') or
                 k.startswith('beta.kubernetes.io/')}
    print(f'  {name}')
    print(f'    capacity:    cpu={cap.get(\"cpu\",\"?\")}  memory={cap.get(\"memory\",\"?\")}  pods={cap.get(\"pods\",\"?\")}')
    print(f'    allocatable: cpu={alloc.get(\"cpu\",\"?\")}  memory={alloc.get(\"memory\",\"?\")}  pods={alloc.get(\"pods\",\"?\")}')
    for t in taints:
        print(f'    taint: {t.get(\"key\")}={t.get(\"value\",\"\")}:{t.get(\"effect\")}')
    for k, v in labels.items():
        print(f'    label: {k}={v}')
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "NAMESPACE INVENTORY"
# =============================================================================

NS_LIST=$(kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
NS_COUNT=$(echo "$NS_LIST" | wc -l)
info "Total namespaces: $NS_COUNT"
echo "$NS_LIST" | tee -a "$REPORT_FILE"

SYSTEM_NS="kube-system kube-public kube-node-lease"
USER_NS=()
for ns in $NS_LIST; do
  echo "$SYSTEM_NS" | grep -qw "$ns" || USER_NS+=("$ns")
done
info "User namespaces : ${#USER_NS[@]}"

# Namespace-level annotations (PSA labels, etc.)
info "Namespace Pod Security Admission labels:"
kubectl get ns -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ns in d.get('items', []):
    name = ns['metadata']['name']
    labels = ns['metadata'].get('labels', {})
    psa = {k: v for k, v in labels.items() if 'pod-security.kubernetes.io' in k}
    if psa:
        for k, v in psa.items():
            print(f'  {name}: {k}={v}')
    else:
        print(f'  {name}: (no PSA labels — enforce/warn/audit not set)')
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "DEPRECATED API DETECTION"
# =============================================================================
#
# We use kubectl api-versions (a single lightweight API call) to check which
# deprecated groups are still served, then query each type individually.
# We never do "kubectl get all -o yaml" — that hangs on clusters with many
# resources (like storage-bench workloads producing thousands of pods).

info "Fetching served API versions from cluster (single fast request)..."
SERVED_APIS=$(kubectl api-versions 2>/dev/null)
echo "$SERVED_APIS" > "$REPORT_DIR/served-api-versions.txt"
info "Saved to: $REPORT_DIR/served-api-versions.txt"

if [[ "$HAVE_PLUTO" == "true" ]]; then
  info "Running pluto in-cluster scan (target: k8s=v1.32.0)..."
  pluto detect-all-in-cluster \
    --target-versions k8s=v1.32.0 \
    --output wide 2>&1 | tee -a "$REPORT_FILE" "$DEPRECATED_APIS_FILE" || true
else
  info "Checking each deprecated API group..."

  # policy/v1beta1 — PodSecurityPolicy + PodDisruptionBudget (removed 1.25)
  if echo "$SERVED_APIS" | grep -qx "policy/v1beta1"; then
    warn "policy/v1beta1 is served (PodSecurityPolicy + PDB removed in 1.25)"
    PSP_LIST=$(kubectl get psp --no-headers --ignore-not-found 2>/dev/null || true)
    [[ -n "$PSP_LIST" ]] && { warn "  PodSecurityPolicy resources exist — MUST migrate to PSA"; echo "$PSP_LIST" | tee -a "$REPORT_FILE"; }
    PDB_LIST=$(kubectl get pdb --all-namespaces --no-headers --ignore-not-found 2>/dev/null || true)
    [[ -n "$PDB_LIST" ]] && { warn "  PodDisruptionBudgets present (stored as policy/v1beta1 — re-create as policy/v1)"; echo "$PDB_LIST" | tee -a "$REPORT_FILE"; }
  else
    ok "policy/v1beta1 not served"
  fi

  # autoscaling/v2beta1 — HPA (removed 1.25)
  if echo "$SERVED_APIS" | grep -qx "autoscaling/v2beta1"; then
    warn "autoscaling/v2beta1 HPA is served (removed in 1.25)"
    kubectl get hpa --all-namespaces --no-headers --ignore-not-found 2>/dev/null | tee -a "$REPORT_FILE" || true
  else
    ok "autoscaling/v2beta1 not served"
  fi

  # autoscaling/v2beta2 — HPA (removed 1.26)
  if echo "$SERVED_APIS" | grep -qx "autoscaling/v2beta2"; then
    warn "autoscaling/v2beta2 HPA is served (removed in 1.26)"
  else
    ok "autoscaling/v2beta2 not served"
  fi

  # batch/v1beta1 — CronJob (removed 1.25)
  if echo "$SERVED_APIS" | grep -qx "batch/v1beta1"; then
    warn "batch/v1beta1 CronJob is served (removed in 1.25)"
    kubectl get cronjob --all-namespaces --no-headers --ignore-not-found 2>/dev/null | tee -a "$REPORT_FILE" || true
  else
    ok "batch/v1beta1 not served"
  fi

  # networking.k8s.io/v1beta1 — Ingress (removed 1.22)
  if echo "$SERVED_APIS" | grep -qx "networking.k8s.io/v1beta1"; then
    warn "networking.k8s.io/v1beta1 Ingress is served (removed in 1.22)"
    kubectl get ingress --all-namespaces --no-headers --ignore-not-found 2>/dev/null | tee -a "$REPORT_FILE" || true
  else
    ok "networking.k8s.io/v1beta1 not served"
  fi

  # discovery.k8s.io/v1beta1 — EndpointSlice (removed 1.25)
  if echo "$SERVED_APIS" | grep -qx "discovery.k8s.io/v1beta1"; then
    warn "discovery.k8s.io/v1beta1 EndpointSlice is served (removed in 1.25)"
  else
    ok "discovery.k8s.io/v1beta1 not served"
  fi

  # node.k8s.io/v1beta1 — RuntimeClass (removed 1.25)
  if echo "$SERVED_APIS" | grep -qx "node.k8s.io/v1beta1"; then
    warn "node.k8s.io/v1beta1 RuntimeClass is served (removed in 1.25)"
    kubectl get runtimeclass --no-headers --ignore-not-found 2>/dev/null | tee -a "$REPORT_FILE" || true
  else
    ok "node.k8s.io/v1beta1 not served"
  fi

  # storage.k8s.io/v1beta1 — CSIStorageCapacity (removed 1.27)
  if echo "$SERVED_APIS" | grep -qx "storage.k8s.io/v1beta1"; then
    warn "storage.k8s.io/v1beta1 CSIStorageCapacity is served (removed in 1.27)"
  else
    ok "storage.k8s.io/v1beta1 not served"
  fi

  # flowcontrol v1beta1/v1beta2 (removed 1.26 / 1.29)
  for fc_api in "flowcontrol.apiserver.k8s.io/v1beta1" "flowcontrol.apiserver.k8s.io/v1beta2"; do
    if echo "$SERVED_APIS" | grep -qx "$fc_api"; then
      warn "$fc_api FlowSchema/PriorityLevelConfiguration is served (deprecated)"
    else
      ok "$fc_api not served"
    fi
  done

  # Scan Helm release manifests for deprecated apiVersions
  if [[ "$HAVE_HELM" == "true" ]]; then
    info "Scanning Helm release manifests for deprecated apiVersions..."
    HELM_DEPR_COUNT=0
    while IFS=$'\t' read -r rel_name rel_ns; do
      MANIFEST=$(helm get manifest "$rel_name" -n "$rel_ns" 2>/dev/null || true)
      for pattern in \
          "apiVersion: batch/v1beta1" \
          "apiVersion: autoscaling/v2beta1" \
          "apiVersion: autoscaling/v2beta2" \
          "apiVersion: policy/v1beta1" \
          "apiVersion: networking.k8s.io/v1beta1" \
          "apiVersion: extensions/v1beta1"; do
        if echo "$MANIFEST" | grep -q "$pattern"; then
          warn "  Helm $rel_ns/$rel_name uses deprecated: $pattern"
          ((HELM_DEPR_COUNT++)) || true
        fi
      done
    done < <(helm list --all-namespaces -o json 2>/dev/null | \
      python3 -c "
import json, sys
for r in json.load(sys.stdin):
    print(r['name'] + '\t' + r['namespace'])
" 2>/dev/null || true)
    [[ "$HELM_DEPR_COUNT" -eq 0 ]] && ok "No deprecated apiVersions in Helm manifests"
  fi

  # HPA metric field shape check (v2beta1 shape vs v2)
  info "Checking HPA metric shapes..."
  kubectl get hpa --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for hpa in d.get('items',[]):
    ns, name = hpa['metadata']['namespace'], hpa['metadata']['name']
    for m in hpa.get('spec',{}).get('metrics',[]):
        for mtype in ('resource','pods','object','external'):
            mm = m.get(mtype, {})
            if 'targetAverageValue' in mm or 'targetAverageUtilization' in mm:
                print(f'  {ns}/{name}: v2beta1 metric field shape — needs conversion')
" 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

# =============================================================================
section "POD SECURITY POLICY (REMOVED IN 1.25)"
# =============================================================================

# --ignore-not-found suppresses "resource not found" but NOT "resource type not found".
# On 1.25+ clusters the psp API group is removed; kubectl exits 1, killing the script
# under set -euo pipefail.  The `|| PSP_COUNT=0` guards against that.
PSP_COUNT=$(kubectl get psp --no-headers --ignore-not-found 2>/dev/null | wc -l) || PSP_COUNT=0
if [[ "$PSP_COUNT" -gt 0 ]]; then
  error "Found $PSP_COUNT PodSecurityPolicies — MUST migrate to Pod Security Admission before 1.32"
  kubectl get psp -o yaml --ignore-not-found 2>/dev/null | tee "$PSP_FILE" || true
  info "Saved PSP details to $PSP_FILE"
else
  ok "No PodSecurityPolicies found (API group not served or no objects)"
fi

# =============================================================================
section "STORAGE: IN-TREE PROVISIONER CHECK (deprecated -> CSI)"
# =============================================================================

kubectl get storageclass -o json > "$STORAGE_FILE" 2>/dev/null || true
info "StorageClasses saved to $STORAGE_FILE"

INTREE_SC=$(jq -r '
  .items[] |
  select(.provisioner | test("kubernetes.io/(azure-disk|azure-file|gce-pd|aws-ebs)")) |
  "  \(.metadata.name) -> \(.provisioner)"
' "$STORAGE_FILE" 2>/dev/null || true)

if [[ -n "$INTREE_SC" ]]; then
  warn "In-tree provisioners found (must migrate to CSI):"
  echo "$INTREE_SC" | tee -a "$REPORT_FILE"
  warn "Replace with: disk.csi.azure.com or file.csi.azure.com"
else
  ok "No in-tree provisioner StorageClasses found"
fi

kubectl get storageclass -o wide 2>&1 | tee -a "$REPORT_FILE"

# =============================================================================
section "PERSISTENT VOLUME CLAIMS"
# =============================================================================

kubectl get pvc --all-namespaces -o json > "$PVC_FILE" 2>/dev/null || true
PVC_COUNT=$(jq '.items | length' "$PVC_FILE" 2>/dev/null || echo "0")
info "Total PVCs: $PVC_COUNT"
kubectl get pvc --all-namespaces -o wide 2>&1 | tee -a "$REPORT_FILE"

DISK_PVCS=$(jq -r '
  .items[] |
  select(.spec.storageClassName | ascii_downcase |
         test("azure-disk|managed|premium|standard|managed-csi")) |
  "  \(.metadata.namespace)/\(.metadata.name) -> \(.spec.storageClassName) [\(.spec.resources.requests.storage)]"
' "$PVC_FILE" 2>/dev/null || true)
[[ -n "$DISK_PVCS" ]] && { info "Azure Disk PVCs (require snapshot+clone):"; echo "$DISK_PVCS" | tee -a "$REPORT_FILE"; }

FILE_PVCS=$(jq -r '
  .items[] |
  select(.spec.storageClassName | ascii_downcase | test("azure-file|azurefile")) |
  "  \(.metadata.namespace)/\(.metadata.name) -> \(.spec.storageClassName) [\(.spec.resources.requests.storage)]"
' "$PVC_FILE" 2>/dev/null || true)
[[ -n "$FILE_PVCS" ]] && { info "Azure File PVCs (share reuse possible):"; echo "$FILE_PVCS" | tee -a "$REPORT_FILE"; }

# =============================================================================
section "WORKLOAD INVENTORY"
# =============================================================================

TOTAL_DEPLOY=$(kubectl get deploy  --all-namespaces --no-headers 2>/dev/null | wc -l)
TOTAL_STS=$(   kubectl get sts     --all-namespaces --no-headers 2>/dev/null | wc -l)
TOTAL_DS=$(    kubectl get ds      --all-namespaces --no-headers 2>/dev/null | wc -l)
TOTAL_JOB=$(   kubectl get job     --all-namespaces --no-headers 2>/dev/null | wc -l)
TOTAL_CRON=$(  kubectl get cronjob --all-namespaces --no-headers 2>/dev/null | wc -l)
TOTAL_POD=$(   kubectl get pod     --all-namespaces --no-headers 2>/dev/null | wc -l)

info "Deployments   : $TOTAL_DEPLOY"
info "StatefulSets  : $TOTAL_STS"
info "DaemonSets    : $TOTAL_DS"
info "Jobs          : $TOTAL_JOB"
info "CronJobs      : $TOTAL_CRON"
info "Running Pods  : $TOTAL_POD"

info "Per-namespace workload breakdown:"
for ns in "${USER_NS[@]}"; do
  D=$(kubectl get deploy  -n "$ns" --no-headers --ignore-not-found 2>/dev/null | wc -l)
  S=$(kubectl get sts     -n "$ns" --no-headers --ignore-not-found 2>/dev/null | wc -l)
  C=$(kubectl get cronjob -n "$ns" --no-headers --ignore-not-found 2>/dev/null | wc -l)
  P=$(kubectl get pod     -n "$ns" --no-headers --ignore-not-found 2>/dev/null | wc -l)
  info "  $ns: deployments=$D statefulsets=$S cronjobs=$C pods=$P"
done

# =============================================================================
section "EXTERNAL SERVICES (LoadBalancer / NodePort)"
# =============================================================================

kubectl get svc --all-namespaces -o json 2>/dev/null | jq -r '
  .items[] |
  select(.spec.type == "LoadBalancer" or .spec.type == "NodePort") |
  "  \(.metadata.namespace)/\(.metadata.name)  type=\(.spec.type)  ip=\(.status.loadBalancer.ingress[0].ip // "pending")"
' 2>/dev/null | tee "$LB_FILE" | tee -a "$REPORT_FILE" || true

LB_COUNT=$(wc -l < "$LB_FILE")
info "Total external services: $LB_COUNT"
[[ "$LB_COUNT" -gt 0 ]] && warn "Record all LoadBalancer IPs — required for DNS cutover rollback"

# =============================================================================
section "INGRESS RESOURCES"
# =============================================================================

INGRESS_COUNT=$(kubectl get ingress --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l)
info "Total Ingresses: $INGRESS_COUNT"
kubectl get ingress --all-namespaces -o wide --ignore-not-found 2>&1 | tee -a "$REPORT_FILE"

# =============================================================================
section "CUSTOM RESOURCE DEFINITIONS"
# =============================================================================

CRD_COUNT=$(kubectl get crd --no-headers --ignore-not-found 2>/dev/null | wc -l)
info "Total CRDs: $CRD_COUNT"
kubectl get crd --no-headers -o custom-columns=NAME:.metadata.name,GROUP:.spec.group \
  --ignore-not-found 2>&1 | tee -a "$REPORT_FILE"

# =============================================================================
section "HELM RELEASES"
# =============================================================================

if [[ "$HAVE_HELM" == "true" ]]; then
  helm list --all-namespaces 2>&1 | tee "$HELM_FILE" | tee -a "$REPORT_FILE"
  HELM_COUNT=$(helm list --all-namespaces --short 2>/dev/null | wc -l)
  info "Total Helm releases: $HELM_COUNT"
  if [[ "$HELM_COUNT" -gt 0 ]]; then
    warn "Helm-managed resources should be reinstalled via Helm in the new cluster"
    info "Export Helm values with:"
    helm list --all-namespaces -o json 2>/dev/null | jq -r '
      .[] | "  helm get values \(.name) -n \(.namespace) > helm-values-\(.name).yaml"
    ' | tee -a "$REPORT_FILE"
  fi
else
  warn "helm not available — skipping Helm release check"
  HELM_COUNT=0
fi

# =============================================================================
section "AAD POD IDENTITY (deprecated -> Workload Identity)"
# =============================================================================

# azureidentity CRD may not be installed — guard against resource-type-not-found exit
AZUREIDENTITY_COUNT=$(kubectl get azureidentity --all-namespaces \
  --no-headers --ignore-not-found 2>/dev/null | wc -l) || AZUREIDENTITY_COUNT=0
if [[ "$AZUREIDENTITY_COUNT" -gt 0 ]]; then
  warn "Found $AZUREIDENTITY_COUNT AzureIdentity resources"
  warn "AAD Pod Identity is deprecated — migrate to Azure Workload Identity"
  kubectl get azureidentity --all-namespaces -o wide --ignore-not-found 2>/dev/null | tee -a "$REPORT_FILE" || true
else
  ok "No AAD Pod Identity resources found"
fi

# =============================================================================
section "POD-LEVEL CHECKS (docker socket / resource limits / privileged)"
# =============================================================================
# Single kubectl request for all pod specs. Python3 processes the JSON for
# all three checks. No repeated large fetches.

info "Fetching all pod specs (one request covers all pod checks)..."
kubectl get pods --all-namespaces -o json > "$PODS_JSON" 2>/dev/null \
  || echo '{"items":[]}' > "$PODS_JSON"

POD_CHECK_OUTPUT=$(python3 - "$PODS_JSON" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

docker_socket = []
no_limits     = []
privileged    = []

for pod in data.get("items", []):
    ns   = pod["metadata"]["namespace"]
    name = pod["metadata"]["name"]
    spec = pod.get("spec", {})

    for vol in spec.get("volumes", []):
        if vol.get("hostPath", {}).get("path") == "/var/run/docker.sock":
            docker_socket.append(f"  {ns}/{name}")
            break

    for ctr in spec.get("containers", []) + spec.get("initContainers", []):
        if not ctr.get("resources", {}).get("limits"):
            no_limits.append(f"  {ns}/{name}  container={ctr['name']}")

    for ctr in spec.get("containers", []) + spec.get("initContainers", []):
        if ctr.get("securityContext", {}).get("privileged") is True:
            privileged.append(f"  {ns}/{name}  container={ctr['name']}")

lines = []

lines.append("--- Docker Socket Mounts ---")
if docker_socket:
    lines.append(f"[ERROR] {len(docker_socket)} pod(s) mount /var/run/docker.sock (removed in 1.32+):")
    lines.extend(docker_socket)
    lines.append("        Fix: use /run/containerd/containerd.sock or Kaniko/Buildah")
else:
    lines.append("[OK]    No docker socket mounts found")

lines.append("--- Containers Without Resource Limits ---")
if no_limits:
    lines.append(f"[WARN]  {len(no_limits)} container(s) have no resource limits:")
    lines.extend(no_limits[:30])
    if len(no_limits) > 30:
        lines.append(f"  ... and {len(no_limits)-30} more")
else:
    lines.append("[OK]    All containers have resource limits")

lines.append("--- Privileged Containers ---")
if privileged:
    lines.append(f"[WARN]  {len(privileged)} privileged container(s) (may be blocked by PSA restricted/baseline):")
    lines.extend(privileged[:30])
    if len(privileged) > 30:
        lines.append(f"  ... and {len(privileged)-30} more")
else:
    lines.append("[OK]    No privileged containers found")

print("\n".join(lines))
PYEOF
)

echo "$POD_CHECK_OUTPUT" | tee -a "$REPORT_FILE"

# Update error/warn counts based on pod check results
if echo "$POD_CHECK_OUTPUT" | grep -q "\[ERROR\]"; then
  ((ERROR_COUNT++)) || true
fi
if echo "$POD_CHECK_OUTPUT" | grep -q "\[WARN\]"; then
  ((WARN_COUNT++)) || true
fi

# =============================================================================
section "PERSISTENT VOLUMES"
# =============================================================================

PV_JSON="$REPORT_DIR/persistent-volumes.json"
kubectl get pv -o json > "$PV_JSON" 2>/dev/null || true
PV_COUNT=$(jq '.items | length' "$PV_JSON" 2>/dev/null || echo "0")
info "Total PVs: $PV_COUNT"

jq -r '
  .items[] |
  "  \(.metadata.name)  storageClass=\(.spec.storageClassName // "none")  capacity=\(.spec.capacity.storage // "?")  reclaimPolicy=\(.spec.persistentVolumeReclaimPolicy)  status=\(.status.phase)  provisioner=\(.spec.csi.driver // .spec.azureDisk.kind // .spec.azureFile.secretName // "unknown")"
' "$PV_JSON" 2>/dev/null | tee -a "$REPORT_FILE" || true

# Flag in-tree PV provisioners
INTREE_PV=$(jq -r '
  .items[] |
  select(.spec.azureDisk != null or .spec.azureFile != null) |
  "  \(.metadata.name): in-tree Azure volume (must recreate as CSI)"
' "$PV_JSON" 2>/dev/null || true)
[[ -n "$INTREE_PV" ]] && { warn "In-tree Azure PVs found (require CSI migration):"; echo "$INTREE_PV" | tee -a "$REPORT_FILE"; }

# =============================================================================
section "RESOURCE QUOTAS AND LIMIT RANGES"
# =============================================================================

RQ_COUNT=$(kubectl get resourcequota --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l)
info "Total ResourceQuotas: $RQ_COUNT"
if [[ "$RQ_COUNT" -gt 0 ]]; then
  kubectl get resourcequota --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for rq in d.get('items', []):
    ns   = rq['metadata']['namespace']
    name = rq['metadata']['name']
    hard = rq.get('status', {}).get('hard', {})
    used = rq.get('status', {}).get('used', {})
    print(f'  {ns}/{name}:')
    for k in sorted(hard):
        print(f'    {k}: used={used.get(k,\"0\")} / hard={hard[k]}')
" 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

LR_COUNT=$(kubectl get limitrange --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l)
info "Total LimitRanges: $LR_COUNT"
if [[ "$LR_COUNT" -gt 0 ]]; then
  kubectl get limitrange --all-namespaces 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

# =============================================================================
section "POD DISRUPTION BUDGETS"
# =============================================================================

PDB_JSON="$REPORT_DIR/pod-disruption-budgets.json"
kubectl get pdb --all-namespaces -o json > "$PDB_JSON" 2>/dev/null || true
PDB_COUNT=$(jq '.items | length' "$PDB_JSON" 2>/dev/null || echo "0")
info "Total PodDisruptionBudgets: $PDB_COUNT"
if [[ "$PDB_COUNT" -gt 0 ]]; then
  jq -r '
    .items[] |
    "  \(.metadata.namespace)/\(.metadata.name)  minAvailable=\(.spec.minAvailable // "n/a")  maxUnavailable=\(.spec.maxUnavailable // "n/a")  currentHealthy=\(.status.currentHealthy)  desiredHealthy=\(.status.desiredHealthy)"
  ' "$PDB_JSON" 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

# =============================================================================
section "HORIZONTAL / VERTICAL POD AUTOSCALERS"
# =============================================================================

HPA_JSON="$REPORT_DIR/hpa.json"
kubectl get hpa --all-namespaces -o json > "$HPA_JSON" 2>/dev/null || true
HPA_COUNT=$(jq '.items | length' "$HPA_JSON" 2>/dev/null || echo "0")
info "Total HPAs: $HPA_COUNT"
if [[ "$HPA_COUNT" -gt 0 ]]; then
  jq -r '
    .items[] |
    "  \(.metadata.namespace)/\(.metadata.name)  target=\(.spec.scaleTargetRef.kind)/\(.spec.scaleTargetRef.name)  min=\(.spec.minReplicas // 1)  max=\(.spec.maxReplicas)  currentReplicas=\(.status.currentReplicas)"
  ' "$HPA_JSON" 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

VPA_COUNT=$(kubectl get vpa --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l) || VPA_COUNT=0
info "Total VPAs: $VPA_COUNT"
if [[ "$VPA_COUNT" -gt 0 ]]; then
  kubectl get vpa --all-namespaces --ignore-not-found 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

# =============================================================================
section "RBAC INVENTORY"
# =============================================================================

CR_COUNT=$(kubectl get clusterrole --no-headers --ignore-not-found 2>/dev/null | grep -vc "^system:") || CR_COUNT=0
CRB_COUNT=$(kubectl get clusterrolebinding --no-headers --ignore-not-found 2>/dev/null | grep -vc "^system:") || CRB_COUNT=0
R_COUNT=$(kubectl get role --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l) || R_COUNT=0
RB_COUNT=$(kubectl get rolebinding --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l) || RB_COUNT=0
SA_COUNT=$(kubectl get sa --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l) || SA_COUNT=0

info "Non-system ClusterRoles       : $CR_COUNT"
info "Non-system ClusterRoleBindings: $CRB_COUNT"
info "Roles (all namespaces)        : $R_COUNT"
info "RoleBindings (all namespaces) : $RB_COUNT"
info "ServiceAccounts               : $SA_COUNT"

# Save full lists to files
kubectl get clusterrole --no-headers --ignore-not-found 2>/dev/null \
  | grep -v "^system:" > "$REPORT_DIR/clusterroles.txt" || true
kubectl get clusterrolebinding --no-headers --ignore-not-found 2>/dev/null \
  | grep -v "^system:" > "$REPORT_DIR/clusterrolebindings.txt" || true
info "RBAC details saved to $REPORT_DIR/clusterroles.txt and clusterrolebindings.txt"

# ServiceAccounts with Workload Identity annotations
info "ServiceAccounts with azure.workload.identity annotations:"
kubectl get sa --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
found = []
for sa in d.get('items', []):
    ns   = sa['metadata']['namespace']
    name = sa['metadata']['name']
    ann  = sa['metadata'].get('annotations', {})
    wi   = {k: v for k, v in ann.items() if 'azure.workload.identity' in k or 'eks.amazonaws.com' in k}
    if wi:
        for k, v in wi.items():
            found.append(f'  {ns}/{name}: {k}={v}')
if found:
    for f in found:
        print(f)
else:
    print('  (none found — if workloads use Azure resources, Workload Identity annotations are required in new cluster)')
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "NETWORK POLICIES"
# =============================================================================

NETPOL_JSON="$REPORT_DIR/network-policies.json"
kubectl get networkpolicy --all-namespaces -o json > "$NETPOL_JSON" 2>/dev/null || true
NP_COUNT=$(jq '.items | length' "$NETPOL_JSON" 2>/dev/null || echo "0")
info "Total NetworkPolicies: $NP_COUNT"
if [[ "$NP_COUNT" -gt 0 ]]; then
  jq -r '
    .items[] |
    "  \(.metadata.namespace)/\(.metadata.name)  policyTypes=\(.spec.policyTypes // [] | join(","))"
  ' "$NETPOL_JSON" 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

# =============================================================================
section "CONFIGMAPS AND SECRETS (counts)"
# =============================================================================

CM_TOTAL=$(kubectl get configmap --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l) || CM_TOTAL=0
SEC_TOTAL=$(kubectl get secret --all-namespaces --no-headers --ignore-not-found 2>/dev/null | wc -l) || SEC_TOTAL=0
info "Total ConfigMaps : $CM_TOTAL"
info "Total Secrets    : $SEC_TOTAL"

# Secret type breakdown
info "Secret type breakdown:"
kubectl get secret --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
from collections import Counter
d = json.load(sys.stdin)
types = Counter(s.get('type','unknown') for s in d.get('items',[]))
for t, c in sorted(types.items(), key=lambda x: -x[1]):
    print(f'  {c:4d}  {t}')
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "POD HEALTH: UNHEALTHY PODS"
# =============================================================================
# Uses the already-fetched PODS_JSON — no extra kubectl call needed.

info "Checking pod health from cached pod JSON..."
python3 - "$PODS_JSON" <<'PYEOF' | tee -a "$REPORT_FILE" || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

pending = []; crash = []; oom = []; not_running = []; orphaned = []
for pod in data.get("items", []):
    ns   = pod["metadata"]["namespace"]
    name = pod["metadata"]["name"]
    phase = pod.get("status", {}).get("phase", "Unknown")
    owners = pod["metadata"].get("ownerReferences", [])
    if not owners:
        orphaned.append(f"  {ns}/{name}  phase={phase}")
    if phase == "Pending":
        reason = pod.get("status", {}).get("conditions", [{}])[0].get("reason", "")
        pending.append(f"  {ns}/{name}  reason={reason}")
    for cs in pod.get("status", {}).get("containerStatuses", []):
        state = cs.get("state", {})
        waiting = state.get("waiting", {})
        if waiting.get("reason") == "CrashLoopBackOff":
            crash.append(f"  {ns}/{name}  container={cs['name']}  restarts={cs.get('restartCount',0)}")
        term = state.get("terminated", {})
        if term.get("reason") == "OOMKilled":
            oom.append(f"  {ns}/{name}  container={cs['name']}")
    if phase not in ("Running", "Succeeded"):
        not_running.append(f"  {ns}/{name}  phase={phase}")

print(f"\n--- Pending Pods ({len(pending)}) ---")
for p in pending: print(p)
print(f"\n--- CrashLoopBackOff Pods ({len(crash)}) ---")
for p in crash: print(p)
print(f"\n--- OOMKilled Pods ({len(oom)}) ---")
for p in oom: print(p)
print(f"\n--- Pods Not Running/Succeeded ({len(not_running)}) ---")
for p in not_running[:50]: print(p)
if len(not_running) > 50:
    print(f"  ... and {len(not_running)-50} more")
print(f"\n--- Orphaned Pods (no ownerReference) ({len(orphaned)}) ---")
for p in orphaned: print(p)
PYEOF

# =============================================================================
section "POD SECURITY: hostNetwork / hostPID / hostIPC"
# =============================================================================
# Uses PODS_JSON — no extra kubectl call.

info "Checking host namespace usage (PSA impact)..."
python3 - "$PODS_JSON" <<'PYEOF' | tee -a "$REPORT_FILE" || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

host_net = []; host_pid = []; host_ipc = []
for pod in data.get("items", []):
    ns   = pod["metadata"]["namespace"]
    name = pod["metadata"]["name"]
    spec = pod.get("spec", {})
    owners = [o.get("kind","") for o in pod["metadata"].get("ownerReferences",[])]
    owner_str = owners[0] if owners else "standalone"
    if spec.get("hostNetwork"):
        host_net.append(f"  {ns}/{name}  owner={owner_str}")
    if spec.get("hostPID"):
        host_pid.append(f"  {ns}/{name}  owner={owner_str}")
    if spec.get("hostIPC"):
        host_ipc.append(f"  {ns}/{name}  owner={owner_str}")

print(f"\n--- hostNetwork Pods ({len(host_net)}) ---")
for p in host_net: print(p)
print(f"\n--- hostPID Pods ({len(host_pid)}) ---")
for p in host_pid: print(p)
print(f"\n--- hostIPC Pods ({len(host_ipc)}) ---")
for p in host_ipc: print(p)
if not (host_net or host_pid or host_ipc):
    print("  [OK]  No hostNetwork/hostPID/hostIPC pods found")
PYEOF

# =============================================================================
section "IMAGE REGISTRY AUDIT"
# =============================================================================
# Uses PODS_JSON — no extra kubectl call.

info "Auditing container image registries..."
python3 - "$PODS_JSON" <<'PYEOF' | tee -a "$REPORT_FILE" || true
import json, sys
from collections import Counter

with open(sys.argv[1]) as f:
    data = json.load(f)

registries = Counter()
latest_tag = []
no_tag     = []

for pod in data.get("items", []):
    ns   = pod["metadata"]["namespace"]
    name = pod["metadata"]["name"]
    spec = pod.get("spec", {})
    for ctr in spec.get("containers", []) + spec.get("initContainers", []):
        img = ctr.get("image", "")
        # parse registry
        parts = img.split("/")
        if len(parts) >= 2 and ("." in parts[0] or ":" in parts[0]):
            reg = parts[0]
        else:
            reg = "docker.io (implicit)"
        registries[reg] += 1
        # tag checks
        tag_part = img.split(":")[-1] if ":" in img else ""
        if tag_part == "latest":
            latest_tag.append(f"  {ns}/{name}: {img}")
        elif ":" not in img or img.endswith("/"):
            no_tag.append(f"  {ns}/{name}: {img} (implicit latest)")

print("\n--- Registry Distribution ---")
for reg, count in registries.most_common():
    print(f"  {count:5d}  {reg}")

print(f"\n--- Images Using :latest Tag ({len(latest_tag)}) ---")
for i in latest_tag[:30]: print(i)
if len(latest_tag) > 30:
    print(f"  ... and {len(latest_tag)-30} more")

print(f"\n--- Images With No Tag ({len(no_tag)}) ---")
for i in no_tag[:30]: print(i)
PYEOF

# Save unique image list
python3 - "$PODS_JSON" <<'PYEOF' > "$REPORT_DIR/all-images.txt" || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
imgs = set()
for pod in data.get("items", []):
    for ctr in pod.get("spec",{}).get("containers",[]) + pod.get("spec",{}).get("initContainers",[]):
        imgs.add(ctr.get("image",""))
for i in sorted(imgs):
    print(i)
PYEOF
info "Unique image list saved to $REPORT_DIR/all-images.txt"

# =============================================================================
section "CRD VERSION AUDIT"
# =============================================================================

info "Checking CRD served/storage versions..."
kubectl get crd -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
v1beta1_crds = []
multi_version = []
for crd in d.get('items', []):
    name = crd['metadata']['name']
    versions = crd.get('spec', {}).get('versions', [])
    served = [v['name'] for v in versions if v.get('served')]
    storage = [v['name'] for v in versions if v.get('storage')]
    if len(served) > 1:
        multi_version.append(f'  {name}: served={served}  storage={storage}')
    # Check if CRD itself was created with v1beta1 schema (legacy)
    ann = crd['metadata'].get('annotations', {})
    if 'kubectl.kubernetes.io/last-applied-configuration' in ann:
        lac = ann['kubectl.kubernetes.io/last-applied-configuration']
        if 'apiextensions.k8s.io/v1beta1' in lac:
            v1beta1_crds.append(f'  {name}: created with apiextensions/v1beta1 (needs schema update)')
print('--- CRDs with multiple served versions ---')
for c in multi_version: print(c)
if not multi_version: print('  (none)')
print('--- CRDs applied as apiextensions/v1beta1 ---')
for c in v1beta1_crds: print(c)
if not v1beta1_crds: print('  (none — all CRDs use apiextensions/v1)')
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "CONFIGMAPS WITH KNOWN DEPRECATED CONTENT"
# =============================================================================

info "Scanning ConfigMaps for known deprecated patterns..."
kubectl get configmap --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
deprecated_patterns = [
    ('apiVersion: apps/v1beta1',  'apps/v1beta1 Deployment/StatefulSet'),
    ('apiVersion: extensions/v1beta1', 'extensions/v1beta1'),
    ('apiVersion: batch/v1beta1', 'batch/v1beta1 CronJob'),
    ('apiVersion: policy/v1beta1', 'policy/v1beta1 PSP/PDB'),
    ('apiVersion: autoscaling/v2beta', 'autoscaling/v2beta HPA'),
]
for cm in d.get('items', []):
    ns   = cm['metadata']['namespace']
    name = cm['metadata']['name']
    for key, val in cm.get('data', {}).items():
        for pattern, label in deprecated_patterns:
            if pattern in val:
                print(f'  {ns}/{name} key={key}: contains {label}')
                break
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "NETWORK: INGRESS CLASS AND TLS"
# =============================================================================

info "Ingress class and TLS certificate details:"
kubectl get ingress --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ing in d.get('items', []):
    ns   = ing['metadata']['namespace']
    name = ing['metadata']['name']
    ann  = ing['metadata'].get('annotations', {})
    ing_class = ann.get('kubernetes.io/ingress.class') or \
                ing.get('spec', {}).get('ingressClassName') or '(none)'
    tls = ing.get('spec', {}).get('tls', [])
    rules = ing.get('spec', {}).get('rules', [])
    hosts = [r.get('host','') for r in rules]
    print(f'  {ns}/{name}  class={ing_class}  hosts={hosts}  tls={len(tls) > 0}')
    for t in tls:
        print(f'    tls-secret={t.get(\"secretName\",\"?\")}  hosts={t.get(\"hosts\",[])}')
" 2>/dev/null | tee -a "$REPORT_FILE" || true

# =============================================================================
section "AZURE-SPECIFIC: NODE POOL DETAILS"
# =============================================================================

if command -v az &>/dev/null; then
  info "Fetching AKS cluster details via az CLI..."
  AKS_CLUSTER=$(kubectl config current-context)
  # Try to identify cluster name and resource group from context
  AKS_RG=$(az aks list --query "[?name=='${AKS_CLUSTER}'].resourceGroup" -o tsv 2>/dev/null | head -1) || AKS_RG=""
  if [[ -n "$AKS_RG" ]]; then
    info "Cluster: $AKS_CLUSTER  ResourceGroup: $AKS_RG"
    az aks nodepool list --cluster-name "$AKS_CLUSTER" --resource-group "$AKS_RG" \
      --query "[].{name:name,count:count,vmSize:vmSize,osType:osType,mode:mode,k8sVersion:orchestratorVersion,autoscale:enableAutoScaling,minCount:minCount,maxCount:maxCount,taints:nodeTaints,labels:nodeLabels}" \
      -o table 2>/dev/null | tee -a "$REPORT_FILE" || true
    info "AKS node pool details saved in report"
  else
    warn "Could not auto-detect AKS cluster name from context '$AKS_CLUSTER' — run manually:"
    warn "  az aks nodepool list --cluster-name NAME --resource-group RG -o table"
  fi
else
  warn "az CLI not found — skipping AKS node pool details"
  warn "Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
fi



# =============================================================================
section "ASSESSMENT SUMMARY"
# =============================================================================

cat <<EOF | tee "$SUMMARY_FILE" | tee -a "$REPORT_FILE"
# AKS Migration Assessment Summary
Generated  : $(date)
Context    : $CURRENT_CTX
K8s version: $SERVER_VERSION

## Cluster Inventory
- Namespaces (user)     : ${#USER_NS[@]}
- Deployments           : $TOTAL_DEPLOY
- StatefulSets          : $TOTAL_STS
- DaemonSets            : $TOTAL_DS
- CronJobs              : $TOTAL_CRON
- HPAs                  : $HPA_COUNT
- PVs                   : $PV_COUNT
- PVCs                  : $PVC_COUNT
- CRDs                  : $CRD_COUNT
- External services     : $LB_COUNT
- NetworkPolicies       : $NP_COUNT
- PodDisruptionBudgets  : $PDB_COUNT
- ConfigMaps            : $CM_TOTAL
- Secrets               : $SEC_TOTAL
- ServiceAccounts       : $SA_COUNT
- ClusterRoles (custom) : $CR_COUNT
- ClusterRoleBindings   : $CRB_COUNT

## Assessment Result
- Warnings : $WARN_COUNT
- Errors   : $ERROR_COUNT

## Saved Artifact Files
- Full report         : $REPORT_FILE
- Served APIs         : $REPORT_DIR/served-api-versions.txt
- Pod specs JSON      : $PODS_JSON
- All images list     : $REPORT_DIR/all-images.txt
- PV JSON             : $REPORT_DIR/persistent-volumes.json
- PVC JSON            : $PVC_FILE
- StorageClass JSON   : $STORAGE_FILE
- HPA JSON            : $REPORT_DIR/hpa.json
- PDB JSON            : $REPORT_DIR/pod-disruption-budgets.json
- NetworkPolicy JSON  : $REPORT_DIR/network-policies.json
- ClusterRoles        : $REPORT_DIR/clusterroles.txt
- ClusterRoleBindings : $REPORT_DIR/clusterrolebindings.txt
- Helm releases       : $HELM_FILE
- SUMMARY             : $SUMMARY_FILE

## Next Step
  bash scripts/02-export-resources.sh
EOF

echo ""
if [[ "$ERROR_COUNT" -gt 0 ]]; then
  echo -e "${RED}Assessment completed with $ERROR_COUNT error(s). Fix errors before migration.${NC}"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  echo -e "${YELLOW}Assessment completed with $WARN_COUNT warning(s). Review before proceeding.${NC}"
else
  echo -e "${GREEN}Assessment passed — cluster ready for export.${NC}"
fi

echo ""
info "Full report saved to: $REPORT_DIR/"
