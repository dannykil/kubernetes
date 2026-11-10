# Kubernetes Local ML Platform

kind 기반 로컬 쿠버네티스 클러스터에 ML/데이터 플랫폼 오픈소스를 구성한 환경입니다.
모든 서비스는 ArgoCD GitOps로 관리되며, 클러스터 삭제 후 재생성해도 데이터가 유지됩니다.

---

## 아키텍처 개요

```
Mac 호스트
├── ~/kind-data/postgres/   ─────────────────────────────────┐
└── ~/kind-data/storage/    ──────────────────────┐          │
        (클러스터 삭제 후에도 데이터 유지)          │          │
                                                   │          │
kind 클러스터 (Docker)                             │          │
├── control-plane                                  │          │
├── worker [role=postgres]  ←── extraMounts ───────│──────────┘
│     └── /mnt/postgres-data                       │
│           └── PostgreSQL PVC                     │
│                 ├── database: airflow             │
│                 ├── database: mlflow              │
│                 ├── database: superset            │
│                 ├── database: grafana             │
│                 └── database: litellm             │
├── worker [role=storage]   ←── extraMounts ────────┘
│     └── /mnt/storage-data
│           ├── /jenkins    → Jenkins PVC
│           ├── /minio      → MinIO PVC
│           ├── /prometheus → Prometheus PVC
│           ├── /kafka      → Kafka PVC
│           ├── /qdrant     → Qdrant PVC
│           └── /redis      → Redis Stack PVC
└── worker (일반 워크로드)
```

---

## 서비스별 스토리지 분류

| 서비스      | 저장소                     | 노드          | 비고                                 |
| ----------- | -------------------------- | ------------- | ------------------------------------ |
| Airflow     | PostgreSQL (`airflow` DB)  | postgres 노드 | 워크플로우 메타데이터                |
| MLflow      | PostgreSQL (`mlflow` DB)   | postgres 노드 | 실험/런 메타데이터, 아티팩트는 MinIO |
| Superset    | PostgreSQL (`superset` DB) | postgres 노드 | 대시보드/유저 데이터                 |
| Grafana     | PostgreSQL (`grafana` DB)  | postgres 노드 | 대시보드/유저 데이터                 |
| LiteLLM     | PostgreSQL (`litellm` DB)  | postgres 노드 | 프록시 사용량/키. 응답 캐시는 Redis  |
| Jenkins     | 파일시스템 PVC             | storage 노드  | JENKINS_HOME                         |
| MinIO       | 파일시스템 PVC             | storage 노드  | 오브젝트 스토리지                    |
| Prometheus  | 파일시스템 PVC             | storage 노드  | TSDB (시계열 데이터)                 |
| Kafka       | 파일시스템 PVC             | storage 노드  | 메시지 로그                          |
| Qdrant      | 파일시스템 PVC             | storage 노드  | 벡터 데이터                          |
| Redis Stack | 파일시스템 PVC             | storage 노드  | 캐시 + RedisInsight                  |

---

## 디렉토리 구조

```
kubernetes/
├── kind-config.yaml          # kind 클러스터 설정 (node labels + extraMounts)
├── postgres/                 # 공유 PostgreSQL (공식 postgres:16-alpine 이미지)
│   ├── storageclass.yaml
│   ├── pv.yaml
│   ├── pvc.yaml
│   ├── configmap.yaml
│   ├── service.yaml
│   └── statefulset.yaml
├── storage/                  # 파일시스템 서비스용 PV
│   ├── storageclass.yaml
│   ├── pv-jenkins.yaml
│   ├── pv-minio.yaml
│   ├── pv-prometheus.yaml
│   ├── pv-kafka.yaml
│   ├── pv-qdrant.yaml
│   └── pv-redis.yaml
├── airflow/values.yaml       # 외부 PostgreSQL 연동
├── mlflow/values.yaml        # 외부 PostgreSQL + MinIO 연동
├── superset/superset-values-dev.yaml  # 외부 PostgreSQL 연동
├── grafana/values.yaml       # 외부 PostgreSQL + Prometheus 데이터소스
├── jenkins/values.yaml       # hostPath PVC
├── minio/values.yaml         # hostPath PVC
├── prometheus/values.yaml    # hostPath PVC, Grafana 번들 비활성화
├── kafka/
│   ├── operator-values.yaml  # Strimzi operator
│   └── cluster.yaml          # KafkaNodePool + Kafka CR
├── litellm/
│   ├── values.yaml           # 공유 PostgreSQL + Redis 캐시
│   └── manifests/            # DB 시크릿, litellm DB 생성 Job
├── qdrant/values.yaml        # hostPath PVC
├── redis/                    # Redis Stack (이미지에 RedisInsight 포함)
│   ├── pvc.yaml
│   ├── service.yaml
│   └── statefulset.yaml
└── argocd/
    ├── application-of-apps.yaml      # 전체 배포 진입점 (단일 명령)
    ├── application-postgres.yaml
    ├── application-storage.yaml
    ├── application-airflow.yaml
    ├── application-mlflow.yaml
    ├── application-superset.yaml
    ├── application-grafana.yaml
    ├── application-prometheus.yaml
    ├── application-jenkins.yaml
    ├── application-minio.yaml
    ├── application-kafka.yaml
    ├── application-litellm.yaml
    ├── application-qdrant.yaml
    └── application-redis.yaml
```

---

## 최초 실행 방법

### 1. Mac /etc/hosts 설정 (최초 1회)

```bash
sudo sh -c 'echo "127.0.0.1 argocd.local airflow.local mlflow.local superset.local grafana.local prometheus.local jenkins.local minio.local litellm.local qdrant.local redis.local" >> /etc/hosts'
```

### 2. Mac 호스트에 데이터 디렉토리 생성

```bash
mkdir -p ~/kind-data/postgres
mkdir -p ~/kind-data/storage/jenkins
mkdir -p ~/kind-data/storage/minio
mkdir -p ~/kind-data/storage/prometheus
mkdir -p ~/kind-data/storage/kafka
mkdir -p ~/kind-data/storage/qdrant
mkdir -p ~/kind-data/storage/redis
```

### 3. kind 클러스터 생성

```bash
kind create cluster --config ./kubernetes/kind-config.yaml
```

### 4. ArgoCD 설치

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd --namespace argocd
# 포트 포워딩 (브라우저 접속용)
# 브라우저에서 **https://localhost:8080**으로 접속
kubectl port-forward svc/argocd-server -n argocd 8080:443
# 초기 비밀번호 확인
# 로그인 아이디는 admin이며, 비밀번호는 쿠버네티스 시크릿에 암호화되어 저장되어 있습니다. 아래 명령어로 확인하세요.
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

### 5. 전체 서비스 한 번에 배포

```bash
kubectl apply -f argocd/application-of-apps.yaml -n argocd
```

ArgoCD가 Git 저장소를 읽어 sync-wave 순서대로 자동 배포합니다.

```
wave 0: infra (dashboard, ingress-nginx), postgres-storage (PV/PVC/PostgreSQL), storage (PV)
wave 1: kafka-operator (Strimzi)
wave 2: airflow, mlflow, superset, grafana, prometheus, jenkins, minio, kafka-cluster, qdrant, redis
wave 3: litellm
```

### 6. 서비스 접속 (포트 포워딩 불필요)

모든 서비스는 Ingress를 통해 도메인으로 직접 접속합니다.

| 서비스       | URL                     |
| ------------ | ----------------------- |
| ArgoCD       | https://argocd.local    |
| Airflow      | http://airflow.local    |
| MLflow       | http://mlflow.local     |
| Superset     | http://superset.local   |
| Grafana      | http://grafana.local    |
| Prometheus   | http://prometheus.local |
| Jenkins      | http://jenkins.local    |
| MinIO        | http://minio.local      |
| LiteLLM      | http://litellm.local    |
| Qdrant       | http://qdrant.local     |
| RedisInsight | http://redis.local      |

ArgoCD 초기 비밀번호 확인:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## 클러스터 재생성 시

데이터는 Mac 호스트(`~/kind-data/`)에 남아있으므로 아래 순서로 복구합니다.

```bash
# 1. 클러스터 삭제 (~/kind-data/ 는 그대로 유지됨)
kind delete cluster

# 2. 클러스터 재생성
kind create cluster --config ./kubernetes/kind-config.yaml

# 3. ArgoCD 재설치 후 App of Apps 한 번 적용
helm install argocd argo/argo-cd --namespace argocd
kubectl apply -f argocd/application-of-apps.yaml -n argocd
```

---

## PostgreSQL 접속 정보

| 항목                 | 값                                                    |
| -------------------- | ----------------------------------------------------- |
| Host (클러스터 내부) | `postgres-postgresql.postgres.svc.cluster.local`      |
| Port                 | `5432`                                                |
| User                 | `postgres`                                            |
| Password             | `postgres`                                            |
| Databases            | `airflow`, `mlflow`, `superset`, `grafana`, `litellm` |

이미 초기화된 데이터 디렉터리에는 `postgres-init` SQL이 다시 실행되지 않습니다. `litellm` 데이터베이스는 LiteLLM Application의 `litellm-create-database` Job이 만듭니다.

## LiteLLM / Qdrant / Redis

| 항목               | 값                                                                         |
| ------------------ | -------------------------------------------------------------------------- |
| LiteLLM UI         | http://litellm.local                                                       |
| LiteLLM master key | `admin`                                                                    |
| LiteLLM DB         | 공유 PostgreSQL `litellm`                                                  |
| Qdrant             | http://qdrant.local , 클러스터 내부 `qdrant.qdrant.svc.cluster.local:6333` |
| Redis              | `redis-stack.redis.svc.cluster.local:6379` (비밀번호 없음)                 |
| RedisInsight       | http://redis.local                                                         |

LiteLLM 모델 `api_base`는 맥에서 띄운 Ollama(`host.docker.internal:11434`)를 가리킵니다. kind 파드에서는 이 이름이 해석되지 않으므로, 호출 전에 파드에서 도달하는 주소로 `litellm/values.yaml`을 바꿉니다.

---

## 클라우드 전환 시

각 서비스 values 파일의 PostgreSQL host를 클라우드 관리형 DB 엔드포인트로 변경하고,
`postgres/` 디렉토리의 ArgoCD Application을 비활성화하면 됩니다.

```yaml
# 예: AWS RDS 전환 시 각 values.yaml의 host만 변경
host: my-rds-instance.xxxxxxxx.ap-northeast-2.rds.amazonaws.com
```

# ☸️ Kubernetes Pod 문제 진단 & 트러블슈팅 치트시트

쿠버네티스 파드가 `ContainerCreating`, `PodInitializing`, `Pending` 등 정상적으로 뜨지 않고 멈춰있을 때 단계별로 원인을 찾아내는 명령어 모음집입니다.

---

## 1단계: 실시간 이벤트 & 상태 모니터링 (가장 먼저 확인할 것)

파드가 생성되는 과정에서 시스템 내부적으로 어떤 작업(이미지 다운로드, 볼륨 연결 등)이 지연되거나 실패하는지 실시간으로 추적합니다.

### 🔹 특정 네임스페이스의 전체 이벤트 실시간 모니터링

```bash
kubectl get events -n <네임스페이스명> --watch
```

### 🔹 문제가 발생하는 특정 파드의 이벤트만 실시간 필터링

```bash
kubectl get events --watch --field-selector involvedObject.name=<파드명> -n <네임스페이스명>
```

---

## 2단계: 파드 상세 분석 및 원인 진단

파드의 상태가 변하지 않을 때, 쿠버네티스가 기록한 진짜 에러 로그와 상태 메시지를 확인합니다. 출력 결과의 맨 아래 **`Events:`** 항목을 분석하는 것이 핵심입니다.

### 🔹 파드 상세 정보 및 시스템 이벤트 확인

```bash
kubectl describe pod <파드명> -n <네임스페이스명>
```

- **대표적인 에러 메시지 종류:**
  - `ErrImagePull` / `ImagePullBackOff`: 컨테이너 이미지를 다운로드하지 못함 (경로 오류 또는 네트워크 문제).
  - `FailedMount` / `Volume`: 스토리지(볼륨) 연결 실패.
  - `FailedScheduling`: 노드에 CPU/메모리 리소스가 부족하여 파드를 배치하지 못함.

---

## 3단계: 파드 상태별 로그 확인 방법

파드의 단계(Lifecycle)에 따라 로그를 볼 수 있는 명령어가 다릅니다.

### ❌ [ContainerCreating] 상태인 경우

- 애플리케이션이 켜지기 전이므로 `kubectl logs` 명령어를 **사용할 수 없습니다**.
- 반드시 **1단계의 `kubectl get events`** 또는 **2단계의 `kubectl describe pod`**로 진단해야 합니다.

### ⚠️ [PodInitializing] 상태인 경우 (Init Container 구동 중)

- 메인 컨테이너는 아직 안 켜졌지만, **초기화 컨테이너(Init Container)**가 돌고 있는 상태입니다.
- 특정 초기화 컨테이너의 이름을 지정하여 로그를 확인할 수 있습니다.

```bash
kubectl logs -f <파드명> -c <초기화-컨테이너명> -n <네임스페이스명>
```

> 💡 _초기화 컨테이너 이름은 `kubectl describe pod <파드명>`의 `Init Containers:` 항목에서 찾을 수 있습니다._

### ✅ [Running] 상태인 경우 (정상 구동 중)

- 컨테이너가 정상적으로 실행 중일 때 애플리케이션의 내부 실시간 로그를 확인합니다.

```bash
kubectl logs -f <파드명> -n <네임스페이스명>
```

---

## 4단계: 스토리지(볼륨) 및 클러스터 리소스 점검

이미지 문제가 없는데도 컨테이너 생성 단계에서 계속 멈춰 있다면 스토리지나 노드 자체의 리소스를 의심해야 합니다.

### 🔹 PersistentVolumeClaim(PVC) 상태 확인

```bash
kubectl get pvc -n <네임스페이스명>
```

- `STATUS`가 **`Pending`**이면 볼륨이 생성되지 않아 파드가 마냥 기다리는 상태입니다.
- 자세한 원인은 `kubectl describe pvc <PVC명> -n <네임스페이스명>`으로 확인합니다.

### 🔹 쿠버네티스 노드 전체 상태 및 리소스 확인

```bash
# 노드가 Ready 상태인지 확인 (NotReady인 경우 노드 장애)
kubectl get nodes

# 노드의 CPU / 메모리 사용량 실시간 확인 (리소스 포화 상태 체크)
kubectl top nodes
```

---

## 5단계: Kind(Kubernetes in Docker) 환경 전용 팁

로컬에서 Kind 클러스터를 사용할 때 대용량 이미지 다운로드 속도로 인해 멈추는 현상을 해결하는 방법입니다.

### 🔹 Kind 가상 노드 내부의 이미지 다운로드 상태 직접 확인

```bash
docker exec -it <가상노드명> crictl images
```

> 💡 _예시: `docker exec -it kind-worker3 crictl images`_

### 🔹 대용량 인터넷 다운로드를 패스하고, 로컬 이미지를 가상 노드에 강제 주입

```bash
kind load docker-image <이미지명>:<태그> --name <클러스터명>
```

> 💡 _예시: `kind load docker-image apache/airflow:3.2.0 --name kind`_

** 이슈 **

1. 중간에 멈춤. 재시작 시 정상
   == Ingress 준비됨 ==
   == storage 준비 대기 ==
   == storage 준비됨 ==
   == postgres 설치 ==
   application.argoproj.io/postgres-storage created
   persistentvolume/postgres-pv created
   statefulset.apps/postgres-postgresql created
   storageclass.storage.k8s.io/postgres-local created
   Error from server (NotFound): error when creating "postgres/configmap.yaml": namespaces "postgres" not found
   Error from server (NotFound): error when creating "postgres/pvc.yaml": namespaces "postgres" not found
   Error from server (NotFound): error when creating "postgres/service.yaml": namespaces "postgres" not found

2. Airflow Init 이후 약 20분 후 이미지 다운로드 및 파드 실행 완료됨 >>> 10분 대기시간 조정(20분 이상)

3. Airflow 설행 완료 후 접속 안됨. ./cluster.sh up 재구동 시 연결됨. Ingress 관련 이슈로 생각되나 로그는 없음.

4. ./cluster.sh up 재구동 시 Airflow Create User Job(외 몇개 더 있음) 재실행됨
