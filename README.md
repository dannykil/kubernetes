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

| 서비스     | 저장소                     | 노드          | 비고                                 |
| ---------- | -------------------------- | ------------- | ------------------------------------ |
| Airflow    | PostgreSQL (`airflow` DB)  | postgres 노드 | 워크플로우 메타데이터                |
| MLflow     | PostgreSQL (`mlflow` DB)   | postgres 노드 | 실험/런 메타데이터, 아티팩트는 MinIO |
| Superset   | PostgreSQL (`superset` DB) | postgres 노드 | 대시보드/유저 데이터                 |
| Grafana    | PostgreSQL (`grafana` DB)  | postgres 노드 | 대시보드/유저 데이터                 |
| LiteLLM    | PostgreSQL (`litellm` DB)  | postgres 노드 | 프록시 사용량/키. 응답 캐시는 Redis  |
| Jenkins    | 파일시스템 PVC             | storage 노드  | JENKINS_HOME                         |
| MinIO      | 파일시스템 PVC             | storage 노드  | 오브젝트 스토리지                    |
| Prometheus | 파일시스템 PVC             | storage 노드  | TSDB (시계열 데이터)                 |
| Kafka      | 파일시스템 PVC             | storage 노드  | 메시지 로그                          |
| Qdrant     | 파일시스템 PVC             | storage 노드  | 벡터 데이터                          |
| Redis Stack | 파일시스템 PVC            | storage 노드  | 캐시 + RedisInsight                  |

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

| 서비스     | URL                     |
| ---------- | ----------------------- |
| ArgoCD     | https://argocd.local    |
| Airflow    | http://airflow.local    |
| MLflow     | http://mlflow.local     |
| Superset   | http://superset.local   |
| Grafana    | http://grafana.local    |
| Prometheus | http://prometheus.local |
| Jenkins    | http://jenkins.local    |
| MinIO      | http://minio.local      |
| LiteLLM    | http://litellm.local    |
| Qdrant     | http://qdrant.local     |
| RedisInsight | http://redis.local    |

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

| 항목                 | 값                                               |
| -------------------- | ------------------------------------------------ |
| Host (클러스터 내부) | `postgres-postgresql.postgres.svc.cluster.local` |
| Port                 | `5432`                                           |
| User                 | `postgres`                                       |
| Password             | `postgres`                                       |
| Databases            | `airflow`, `mlflow`, `superset`, `grafana`, `litellm` |

이미 초기화된 데이터 디렉터리에는 `postgres-init` SQL이 다시 실행되지 않습니다. `litellm` 데이터베이스는 LiteLLM Application의 `litellm-create-database` Job이 만듭니다.

## LiteLLM / Qdrant / Redis

| 항목 | 값 |
| --- | --- |
| LiteLLM UI | http://litellm.local |
| LiteLLM master key | `admin` |
| LiteLLM DB | 공유 PostgreSQL `litellm` |
| Qdrant | http://qdrant.local , 클러스터 내부 `qdrant.qdrant.svc.cluster.local:6333` |
| Redis | `redis-stack.redis.svc.cluster.local:6379` (비밀번호 없음) |
| RedisInsight | http://redis.local |

LiteLLM 모델 `api_base`는 맥에서 띄운 Ollama(`host.docker.internal:11434`)를 가리킵니다. kind 파드에서는 이 이름이 해석되지 않으므로, 호출 전에 파드에서 도달하는 주소로 `litellm/values.yaml`을 바꿉니다.

---

## 클라우드 전환 시

각 서비스 values 파일의 PostgreSQL host를 클라우드 관리형 DB 엔드포인트로 변경하고,
`postgres/` 디렉토리의 ArgoCD Application을 비활성화하면 됩니다.

```yaml
# 예: AWS RDS 전환 시 각 values.yaml의 host만 변경
host: my-rds-instance.xxxxxxxx.ap-northeast-2.rds.amazonaws.com
```
