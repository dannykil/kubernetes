#!/usr/bin/env bash
# kind 클러스터와 그 위의 서비스를 한 명령으로 올리거나 내린다.
# 서비스 추가 방법은 scripts/services.conf 와 scripts/README.md 를 본다.
#
#   ./scripts/cluster.sh up              클러스터, 기반, 목록의 모든 서비스
#   ./scripts/cluster.sh up kind         클러스터와 기반만
#   ./scripts/cluster.sh up jenkins      jenkins 와, 없으면 그 의존성
#   ./scripts/cluster.sh down            클러스터 삭제. ~/kind-data 는 남긴다
#   ./scripts/cluster.sh down kind       down 과 같다
#   ./scripts/cluster.sh down jenkins    그 서비스만 삭제
#   ./scripts/cluster.sh list            서비스 목록

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CLUSTER="kind"
CONTEXT="kind-${CLUSTER}"
CATALOG="${ROOT}/scripts/services.conf"
DATA="${HOME}/kind-data"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "필요한 명령이 없습니다: $1" >&2
    exit 1
  }
}

for cmd in docker kind kubectl helm awk; do
  need "$cmd"
done

usage() {
  cat <<'EOF'
사용법:
  ./scripts/cluster.sh up                 클러스터, 기반, 모든 서비스
  ./scripts/cluster.sh up kind            클러스터와 기반만 (Argo CD, Ingress, PV)
  ./scripts/cluster.sh up <서비스>        그 서비스. 의존성이 없으면 먼저 설치
  ./scripts/cluster.sh down               클러스터 삭제. Mac 의 ~/kind-data 는 유지
  ./scripts/cluster.sh down kind          down 과 같다
  ./scripts/cluster.sh down <서비스>      그 서비스만 삭제. 공유 Postgres/Redis 는 유지
  ./scripts/cluster.sh list               등록된 서비스

삭제는 y 를 입력해야 진행된다. Enter 는 취소다.
EOF
}

catalog_line() {
  local name="$1"
  awk -F'|' -v n="$name" '$1 == n { print; exit }' "$CATALOG"
}

known_service() {
  [[ -n "$(catalog_line "$1")" ]]
}

field() {
  local name="$1" index="$2" line
  line="$(catalog_line "$name")"
  [[ -n "$line" ]] || return 1
  echo "$line" | awk -F'|' -v i="$index" '{ print $i }'
}

each_service() {
  awk -F'|' '$0 !~ /^[[:space:]]*#/ && NF >= 6 { print $1 }' "$CATALOG"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

require_cluster() {
  if ! cluster_exists; then
    echo "kind 클러스터가 없습니다. 먼저 ./scripts/cluster.sh up kind" >&2
    exit 1
  fi
  kubectl config use-context "$CONTEXT" >/dev/null
}

create_cluster() {
  echo "== 데이터 디렉터리 =="
  mkdir -p \
    "${DATA}/postgres" \
    "${DATA}/storage/jenkins" \
    "${DATA}/storage/minio" \
    "${DATA}/storage/prometheus" \
    "${DATA}/storage/kafka" \
    "${DATA}/storage/qdrant" \
    "${DATA}/storage/redis" \
    "${DATA}/storage/neo4j"

  if cluster_exists; then
    echo "== kind 클러스터가 이미 있습니다: ${CLUSTER} =="
  else
    echo "== kind 클러스터 생성 =="
    kind create cluster --name "$CLUSTER" --config kubernetes/kind-config.yaml
  fi
  kubectl config use-context "$CONTEXT" >/dev/null
}

install_argocd() {
  echo "== Argo CD =="
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace
  kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
}

# App of Apps 는 Git 의 Application 을 전부 다시 만든다.
# 서비스 하나만 지우는 명령과 충돌하므로 자동 동기화만 끈다. Application 자체는 지우지 않는다.
suspend_app_of_apps() {
  kubectl get application app-of-apps -n argocd >/dev/null 2>&1 || return 0
  kubectl patch application app-of-apps -n argocd --type json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' \
    >/dev/null 2>&1 || true
  echo "== App of Apps 자동 동기화를 멈췄습니다. 서비스 단위 설치는 이 스크립트가 관리합니다. =="
}

app_synced() {
  local app="$1" sync health
  sync="$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [[ "$sync" == "Synced" && "$health" == "Healthy" ]]
}

service_ready() {
  local name="$1" apps app
  apps="$(field "$name" 3)"
  IFS=',' read -r -a app_list <<< "$apps"
  for app in "${app_list[@]}"; do
    app_synced "$app" || return 1
  done
}

wait_service() {
  local name="$1" i apps app
  apps="$(field "$name" 3)"
  echo "== ${name} 준비 대기 =="
  for i in $(seq 1 120); do
    if service_ready "$name"; then
      echo "== ${name} 준비됨 =="
      return 0
    fi
    if (( i % 12 == 0 )); then
      IFS=',' read -r -a app_list <<< "$apps"
      for app in "${app_list[@]}"; do
        echo "  ${app}: sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo 없음) health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo 없음)"
      done
    fi
    sleep 5
  done
  echo "${name} 이 10분 안에 Synced/Healthy 가 되지 않았습니다. kubectl get application -n argocd" >&2
  return 1
}

ensure_platform() {
  require_cluster
  install_argocd
  suspend_app_of_apps
  echo "== 기반: Ingress, PV =="
  kubectl apply -f argocd/application-infra.yaml -n argocd
  kubectl apply -f argocd/application-storage.yaml -n argocd
  # infra 와 storage 는 서비스 목록 밖이다. Application 상태만 확인한다.
  wait_named_app infra
  wait_named_app storage
}

wait_named_app() {
  local app="$1" i
  echo "== ${app} 준비 대기 =="
  for i in $(seq 1 120); do
    if app_synced "$app"; then
      echo "== ${app} 준비됨 =="
      return 0
    fi
    sleep 5
  done
  echo "${app} 이 아직 Synced/Healthy 가 아닙니다." >&2
  return 1
}

ensure_service() {
  local name="$1" needs dep apps
  if ! known_service "$name"; then
    echo "알 수 없는 서비스입니다: ${name}" >&2
    echo "목록은 ./scripts/cluster.sh list" >&2
    exit 1
  fi
  case " ${ensuring:-} " in
    *" ${name} "*) return 0 ;;
  esac
  ensuring="${ensuring:-} ${name}"

  needs="$(field "$name" 4)"
  if [[ "$needs" != "-" ]]; then
    IFS=',' read -r -a dep_list <<< "$needs"
    for dep in "${dep_list[@]}"; do
      if service_ready "$dep"; then
        echo "== ${dep} 은 이미 실행 중입니다. ${name} 의존성으로 다시 설치하지 않습니다. =="
      else
        echo "== ${name} 의 의존성 ${dep} 이 없습니다. 먼저 구성합니다. =="
        ensure_service "$dep"
      fi
    done
  fi

  if service_ready "$name"; then
    echo "== ${name} 은 이미 실행 중입니다. =="
    return 0
  fi

  echo "== ${name} 설치 =="
  kubectl apply -f "$(field "$name" 2)" -n argocd
  wait_service "$name"
}

confirm() {
  local message="$1" answer
  echo "$message"
  echo "삭제하시겠습니까? [y/N]"
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

dependents_running() {
  local name="$1" other needs dep
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    needs="$(field "$other" 4)"
    [[ "$needs" == "-" ]] && continue
    IFS=',' read -r -a dep_list <<< "$needs"
    for dep in "${dep_list[@]}"; do
      if [[ "$dep" == "$name" ]] && kubectl get application "$(field "$other" 3 | awk -F',' '{print $1}')" -n argocd >/dev/null 2>&1; then
        echo "$other"
      fi
    done
  done < <(each_service)
}

stop_forwards() {
  pkill -f "[s]cripts/up.sh" >/dev/null 2>&1 || true
  local ns
  for ns in argocd airflow jenkins mlflow litellm grafana monitoring superset minio qdrant redis neo4j postgres kafka sample; do
    pkill -f "[k]ubectl port-forward -n ${ns} " >/dev/null 2>&1 || true
  done
}

release_pvs() {
  local name="$1" pvs pv
  pvs="$(field "$name" 6)"
  [[ "$pvs" == "-" ]] && return 0
  IFS=',' read -r -a pv_list <<< "$pvs"
  for pv in "${pv_list[@]}"; do
    kubectl get pv "$pv" >/dev/null 2>&1 || continue
    kubectl patch pv "$pv" --type json \
      -p '[{"op":"remove","path":"/spec/claimRef"}]' \
      >/dev/null 2>&1 || true
    echo "== ${pv} 를 다음 설치에서 다시 붙일 수 있게 claimRef 를 비웠습니다. 디스크 파일은 그대로입니다. =="
  done
}

delete_service() {
  local name="$1" apps app ns running
  apps="$(field "$name" 3)"
  ns="$(field "$name" 5)"
  running="$(dependents_running "$name" || true)"
  if [[ -n "$running" ]]; then
    echo "${name} 을 아직 쓰는 서비스가 있어서 삭제하지 않습니다." >&2
    echo "$running" >&2
    exit 1
  fi

  if ! confirm "${name} 만 삭제합니다. ~/kind-data 의 파일과 다른 서비스는 남습니다."; then
    echo "취소했습니다."
    exit 0
  fi

  suspend_app_of_apps
  IFS=',' read -r -a app_list <<< "$apps"
  for app in "${app_list[@]}"; do
    kubectl delete application "$app" -n argocd --wait=true --timeout=180s --ignore-not-found
  done
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl delete namespace "$ns" --wait=true --timeout=180s
  fi
  release_pvs "$name"
  echo "== ${name} 삭제 완료 =="
}

delete_cluster() {
  if ! confirm "kind 클러스터와 그 안의 서비스를 모두 삭제합니다.
유지: ${DATA} (Postgres, Jenkins, Redis, Qdrant, Neo4j 등의 파일)
함께 사라짐: kind 노드 디스크에만 있던 데이터. Airflow 스케줄러/트리거 로그가 여기에 해당합니다."; then
    echo "취소했습니다."
    exit 0
  fi

  stop_forwards
  if cluster_exists; then
    echo "== kind 클러스터 삭제: ${CLUSTER} =="
    kind delete cluster --name "$CLUSTER"
  else
    echo "== kind 클러스터가 이미 없습니다: ${CLUSTER} =="
  fi

  if [[ ! -d "$DATA" ]]; then
    echo "데이터 디렉터리를 찾지 못했습니다: ${DATA}" >&2
    exit 1
  fi
  echo "== 데이터 디렉터리는 남아 있습니다 =="
  find "$DATA" -maxdepth 2 -type d | sort
}

cmd_list() {
  echo "서비스 | 의존성 | Application"
  awk -F'|' '$0 !~ /^[[:space:]]*#/ && NF >= 6 { printf "%-12s %-18s %s\n", $1, $4, $3 }' "$CATALOG"
}

cmd_up() {
  local target="${1:-}"
  case "$target" in
    "")
      create_cluster
      ensure_platform
      local name
      while IFS= read -r name; do
        ensuring=""
        ensure_service "$name"
      done < <(each_service)
      ;;
    kind)
      create_cluster
      ensure_platform
      ;;
    *)
      require_cluster
      ensure_platform
      ensuring=""
      ensure_service "$target"
      ;;
  esac
}

cmd_down() {
  local target="${1:-}"
  case "$target" in
    ""|kind)
      delete_cluster
      ;;
    *)
      require_cluster
      if ! known_service "$target"; then
        echo "알 수 없는 서비스입니다: ${target}" >&2
        exit 1
      fi
      delete_service "$target"
      ;;
  esac
}

main() {
  local action="${1:-}" target="${2:-}"
  case "$action" in
    up) cmd_up "$target" ;;
    down) cmd_down "$target" ;;
    list) cmd_list ;;
    ""|-h|--help|help) usage ;;
    *)
      echo "알 수 없는 명령입니다: ${action}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
