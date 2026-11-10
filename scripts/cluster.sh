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
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
  forward_service argocd
}

# 포그라운드로 두면 스크립트가 멈춘다. 주소는 setting_*.txt 의 port-forward 와 같다.
# down 은 namespace 기준으로 이 프로세스를 끈다.
start_forward() {
  local ns="$1" label="$2"
  shift 2
  local needle="[k]ubectl port-forward -n ${ns} $*"
  if pgrep -f "$needle" >/dev/null 2>&1; then
    echo "== ${label} =="
    return 0
  fi
  nohup kubectl port-forward -n "$ns" "$@" >>"/tmp/port-forward-${ns}.log" 2>&1 &
  disown || true
  sleep 1
  if pgrep -f "$needle" >/dev/null 2>&1; then
    echo "== ${label} =="
  else
    echo "${label} 포트포워딩을 시작하지 못했습니다. /tmp/port-forward-${ns}.log" >&2
  fi
}

forward_service() {
  local name="$1"
  case "$name" in
    argocd)
      start_forward argocd "Argo CD: https://localhost:8080" svc/argocd-server 8080:443
      ;;
    postgres)
      start_forward postgres "Postgres: localhost:5432" svc/postgres-postgresql 5432:5432
      ;;
    redis)
      start_forward redis "Redis: localhost:6379" svc/redis-stack 6379:6379
      # setting_18: 8001 은 kubectl proxy 가 쓴다. RedisInsight 는 8002 로 연다.
      start_forward redis "RedisInsight: http://localhost:8002" svc/redis-stack 8002:8001
      ;;
    jenkins)
      start_forward jenkins "Jenkins: http://localhost:8081" sts/jenkins 8081:8080
      ;;
    minio)
      start_forward minio "MinIO API: localhost:9000" svc/minio 9000:9000
      start_forward minio "MinIO Console: http://localhost:9001" svc/minio-console 9001:9001
      ;;
    prometheus)
      start_forward monitoring "Prometheus: http://localhost:9090" svc/prometheus-kube-prometheus-prometheus 9090:9090
      start_forward monitoring "Alertmanager: http://localhost:9093" svc/prometheus-kube-prometheus-alertmanager 9093:9093
      ;;
    grafana)
      start_forward grafana "Grafana: http://localhost:3000" svc/grafana 3000:80
      ;;
    airflow)
      start_forward airflow "Airflow: http://localhost:8082" svc/airflow-api-server 8082:8080
      ;;
    mlflow)
      start_forward mlflow "MLflow: http://localhost:5000" svc/mlflow 5000:80
      ;;
    superset)
      start_forward superset "Superset: http://localhost:8088" svc/superset 8088:8088
      ;;
    qdrant)
      start_forward qdrant "Qdrant: http://localhost:6333" svc/qdrant 6333:6333
      ;;
    neo4j)
      start_forward neo4j "Neo4j: http://localhost:7474" svc/neo4j 7474:7474 7687:7687
      ;;
    kafka)
      if kubectl get svc kafka-ui -n kafka >/dev/null 2>&1; then
        start_forward kafka "Kafka UI: http://localhost:8083" svc/kafka-ui 8083:80
      fi
      ;;
    litellm)
      start_forward litellm "LiteLLM: http://localhost:4000" svc/litellm 4000:4000
      ;;
  esac
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

# GitHub 의 infra 는 LoadBalancer Service 를 갖고 있다. kind 는 그 외부 주소를
# 만들지 않으므로, Argo 자동 동기화에 맡기면 up 이 여기서 끝난다.
# 로컬 kind 매니페스트를 적용하고, Deployment 가 Ready 인지만 확인한다.
apply_infra() {
  echo "== Ingress =="
  if kubectl get application infra -n argocd >/dev/null 2>&1; then
    kubectl patch application infra -n argocd --type json \
      -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' \
      >/dev/null 2>&1 || true
    kubectl patch application infra -n argocd --type merge \
      -p '{"operation":null}' >/dev/null 2>&1 || true
  fi
  kubectl apply -f kubernetes/namespaces.yaml
  kubectl apply -f kubernetes/metrics-server.yaml
  kubectl apply -f kubernetes/dashboard.yaml
  kubectl apply -f kubernetes/ingress-nginx-kind.yaml
  kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s
  # Ready 는 상태 포트가 열렸다는 뜻이다. Ingress 검사 webhook(8443)은 그보다 늦게 열린다.
  # 그 전에 적용하면 connection refused 로 스크립트가 끝난다.
  echo "== Ingress webhook 응답 대기 =="
  local i err
  for i in $(seq 1 30); do
    if err="$(kubectl apply -f kubernetes/ingresses.yaml 2>&1)"; then
      echo "$err"
      echo "== Ingress 준비됨 =="
      return 0
    fi
    echo "webhook 이 아직 연결을 받지 않습니다. 재시도 ${i}/30"
    sleep 2
  done
  echo "$err" >&2
  echo "Ingress webhook 이 열리지 않았습니다." >&2
  return 1
}

ensure_platform() {
  require_cluster
  install_argocd
  suspend_app_of_apps
  echo "== 기반: Ingress, PV =="
  kubectl apply -f argocd/application-infra.yaml -n argocd
  kubectl apply -f argocd/application-storage.yaml -n argocd
  apply_infra
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
        forward_service "$dep"
      else
        echo "== ${name} 의 의존성 ${dep} 이 없습니다. 먼저 구성합니다. =="
        ensure_service "$dep"
      fi
    done
  fi

  if service_ready "$name"; then
    echo "== ${name} 은 이미 실행 중입니다. =="
    forward_service "$name"
    return 0
  fi

  echo "== ${name} 설치 =="
  kubectl apply -f "$(field "$name" 2)" -n argocd
  # GitHub 의 postgres 는 PVC(wave 0)가 Healthy 된 뒤에야 StatefulSet 을 만든다.
  # StorageClass 가 WaitForFirstConsumer 라 PVC 는 파드 없이는 영원히 Pending 이다.
  # 로컬 매니페스트로 파드까지 같이 만들어 그 대기를 푼다.
  if [[ "$name" == "postgres" ]]; then
    kubectl apply -f postgres/
  fi
  wait_service "$name"
  forward_service "$name"
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
  pkill -f "[k]ubectl port-forward -n ${ns} " >/dev/null 2>&1 || true
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
