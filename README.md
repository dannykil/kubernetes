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
│                 └── database: grafana             │
├── worker [role=storage]   ←── extraMounts ────────┘
│     └── /mnt/storage-data
│           ├── /jenkins  → Jenkins PVC
│           ├── /minio    → MinIO PVC
│           ├── /prometheus → Prometheus PVC
│           └── /kafka    → Kafka PVC
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
| Jenkins    | 파일시스템 PVC             | storage 노드  | JENKINS_HOME                         |
| MinIO      | 파일시스템 PVC             | storage 노드  | 오브젝트 스토리지                    |
| Prometheus | 파일시스템 PVC             | storage 노드  | TSDB (시계열 데이터)                 |
| Kafka      | 파일시스템 PVC             | storage 노드  | 메시지 로그                          |

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
│   └── pv-kafka.yaml
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
    └── application-kafka.yaml
```

---

## 최초 실행 방법

### 1. Mac /etc/hosts 설정 (최초 1회)

```bash
sudo sh -c 'echo "127.0.0.1 argocd.local airflow.local mlflow.local superset.local grafana.local prometheus.local jenkins.local minio.local" >> /etc/hosts'
```

### 2. Mac 호스트에 데이터 디렉토리 생성

```bash
mkdir -p ~/kind-data/postgres
mkdir -p ~/kind-data/storage/jenkins
mkdir -p ~/kind-data/storage/minio
mkdir -p ~/kind-data/storage/prometheus
mkdir -p ~/kind-data/storage/kafka
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
wave 2: airflow, mlflow, superset, grafana, prometheus, jenkins, minio, kafka-cluster
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
| Databases            | `airflow`, `mlflow`, `superset`, `grafana`       |

---

## 클라우드 전환 시

각 서비스 values 파일의 PostgreSQL host를 클라우드 관리형 DB 엔드포인트로 변경하고,
`postgres/` 디렉토리의 ArgoCD Application을 비활성화하면 됩니다.

```yaml
# 예: AWS RDS 전환 시 각 values.yaml의 host만 변경
host: my-rds-instance.xxxxxxxx.ap-northeast-2.rds.amazonaws.com
```
