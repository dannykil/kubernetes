# 클라우드 플랫폼 진행 순서

로컬 kind에서 검증한 ML/데이터 플랫폼을 AWS에 먼저 올리고, 같은 Git으로 GCP에도 올릴 수 있게 만드는 순서다. 클라우드 자원은 Terraform, 클러스터 안 서비스는 Argo CD가 맡는다.

이 문서는 진행 순서만 정한다. 클러스터와 클라우드 자원은 각 단계를 시작하기로 할 때 만든다.

## 하려는 일

지금 저장소는 맥의 kind 클러스터다. `scripts/cluster.sh`가 kind, Argo CD, Ingress, PV를 올리고, Argo CD가 GitHub `main`의 Application으로 Postgres, Redis, Jenkins, MLflow, Qdrant, Neo4j, Airflow, LiteLLM을 맞춘다.

다음 목표는 이 서비스 정의를 클라우드에서도 쓰는 것이다.

- 로컬 kind는 돈을 쓰기 전에 매니페스트를 확인하는 환경으로 남긴다.
- AWS에 개발용 EKS를 하나 만들고, 위 서비스를 거기에 올린다.
- 클라우드 자원(VPC, EKS, IAM, 디스크)은 Terraform으로 만든다.
- 개발할 때는 `terraform plan`, `terraform apply`를 그대로 친다. 누가 어떤 plan을 적용했는지는 중앙에 남긴다.
- AWS에서 kind와 EKS가 같은 Git으로 각각 배포되는 것을 확인한 뒤, GCP에 GKE를 하나 더 만든다.
- AWS와 GCP는 서비스를 나눠 받는 하나의 클러스터가 아니다. 같은 정의를 올릴 수 있는 별도 클러스터 두 개다. 데이터도 서로 복제하지 않는다.

## 관리 경계

```
개발자 노트북
└── terraform plan / apply          명령은 로컬에서 친다
         │
         ▼
HCP Terraform                       실행, plan, 계정, 시각을 기록한다
         │
         ├── AWS (먼저)              VPC, EKS, IAM, 스토리지
         └── GCP (나중)              VPC, GKE, IAM, 스토리지

GitHub main
         │
         ▼
각 클러스터의 Argo CD               클러스터 안 서비스만 맞춘다
         ├── kind
         ├── EKS
         └── GKE
```

Terraform은 클러스터와 그 바깥 자원을 만든다. Deployment, Helm values, Application은 지금처럼 `argocd/`와 서비스 디렉터리에 둔다. 같은 서비스를 Terraform Helm 프로바이더로도 올리면 Argo CD와 서로 되돌린다.

`scripts/cluster.sh`는 kind 전용 진입점으로 둔다. EKS를 만드는 명령을 이 스크립트에 넣지 않는다.

## 환경마다 갈라지는 것

서비스 목록과 의존성은 `scripts/services.conf` 그대로다. 바뀌는 것은 그 서비스가 붙는 기반이다.

| 항목 | kind (지금) | EKS | GKE |
| --- | --- | --- | --- |
| 클러스터 | Docker, `cluster.sh` | Terraform | Terraform |
| Ingress | NodePort + hostNetwork | AWS Load Balancer | GKE Ingress 또는 nginx LoadBalancer |
| 디스크 | `~/kind-data` hostPath PV | EBS CSI | Compute Engine persistent disk |
| 노드 구분 | `role=postgres`, `role=storage` 라벨 | 노드 그룹 라벨 또는 라벨 제거 | 노드 풀 라벨 또는 라벨 제거 |
| 데이터 | 맥 폴더에 남음 | 클러스터를 지워도 EBS는 별도 | 클러스터를 지워도 디스크는 별도 |
| 이미지 | 공개 레지스트리 pull | 공개 레지스트리, 필요하면 ECR | 공개 레지스트리, 필요하면 Artifact Registry |

`kubernetes/ingress-nginx-kind.yaml`과 `storage/`, `postgres/pv.yaml`의 hostPath는 kind 전용이다. EKS용 파일을 그 위에 덮어쓰지 않고, 클러스터별 values와 매니페스트로 나눈다.

`~/kind-data`는 EKS로 따라가지 않는다. 클라우드 클러스터는 빈 디스크로 시작하고, 데이터가 필요하면 따로 옮긴다.

## 진행 순서

한 단계의 완료 조건을 만족하기 전에 다음 클라우드로 넘어가지 않는다.

### 0. kind를 기준 환경으로 고정한다

완료 조건

- `./scripts/cluster.sh up`으로 켜 둔 서비스가 Argo CD에서 Synced, Healthy다.
- kind에서만 성립하는 파일과 클라우드에서도 쓸 파일을 구분해서 말할 수 있다.
- `services.conf`에서 주석이 아닌 서비스만 클라우드 1차 범위로 둔다. 주석 처리된 MinIO, Prometheus, Grafana, Superset, Kafka, sample은 AWS에 올리기 전에 로컬에서 다시 켠다.

### 1. AWS 계정과 Terraform 실행 기록을 먼저 만든다

클러스터보다 기록 장치를 먼저 둔다. 나중에 붙이면 그 전까지의 apply는 사람 이름이 없는 채 남는다.

완료 조건

- 연습용 AWS 계정에 월 예산 경보가 있다.
- HCP Terraform에 `aws-dev` workspace가 있고, CLI-driven workflow로 연결되어 있다.
- 노트북에서 `terraform plan`을 치면 HCP Terraform에 실행한 계정, 시각, plan이 남는다.
- apply에 쓰는 AWS 자격은 개인 장기 액세스 키가 아니다. HCP Terraform이 맡을 IAM 역할이다.
- 상태 파일은 HCP Terraform에 있다.

이 단계의 Terraform 코드는 VPC를 만들기 전의 뼈대만 있어도 된다. 확인할 것은 자원이 아니라 “누가 명령했는지 남는가”다.

### 2. 네트워크와 EKS만 만든다

완료 조건

- Terraform이 VPC, 서브넷, EKS, 작은 노드 그룹 하나를 만든다.
- `kubectl`이 이 클러스터를 본다.
- 노드가 Ready인 것을 확인한 뒤, 쓰지 않을 때는 노드 그룹을 0으로 줄이거나 클러스터를 지울 수 있다. EKS 컨트롤 플레인은 노드가 없어도 시간당 비용이 나간다.
- 클러스터 안에 Postgres나 Airflow는 아직 없다.

노드는 한 그룹, 작은 인스턴스로 시작한다. 가용 영역 세 개와 다중 NAT는 이 연습의 첫 클러스터 범위 밖이다.

### 3. EKS에 Argo CD와 스토리지 클래스만 올린다

완료 조건

- EKS 안에 Argo CD가 떠 있고 GitHub `main`을 본다.
- 기본 StorageClass가 EBS CSI다. hostPath PV를 가져오지 않았다.
- Ingress가 LoadBalancer로 외부 주소를 받는다. kind의 NodePort, hostNetwork 매니페스트는 적용하지 않았다.
- Argo CD가 관리하는 Application은 아직 없다. 플랫폼이 빈 클러스터에서 정상인지만 확인한다.

Argo CD 설치는 클러스터를 만든 직후 한 번 하는 부트스트랩이다. 그 다음부터 서비스는 Argo CD가 맞춘다.

### 4. 서비스를 의존성 순서로 옮긴다

한 번에 `up`에 해당하는 전체를 올리지 않는다. 하나가 Healthy인 것을 본 뒤 다음으로 간다.

1. Redis. Postgres에 의존하지 않고, PVC가 EBS에 붙는지만 보면 된다.
2. Postgres. Airflow, MLflow, LiteLLM이 이 데이터베이스를 쓴다.
3. Jenkins, Qdrant, Neo4j. 각각 자기 디스크만 있으면 된다.
4. MLflow, Airflow. Postgres가 Ready인 뒤에 올린다.
5. LiteLLM. Postgres와 Redis가 모두 Ready인 뒤에 올린다.

각 서비스는 kind용 values와 EKS용 values를 분리한다. 노드 라벨 `role=postgres`, `role=storage`를 EKS에 만들 계획이 없으면 그 `nodeSelector`는 EKS values에서 뺀다.

`services.conf`에서 주석인 서비스는 이 목록에 넣지 않는다.

### 5. kind와 EKS가 같은 Git을 각각 쓰게 만든다

GCP로 넘어가기 전에, 클러스터가 두 개일 때의 저장소 모양을 여기서 고정한다.

완료 조건

- Application이 클러스터마다 있다. kind용 Application이 EKS 매니페스트를 적용하지 않고, 반대도 없다.
- 차트와 공통 설정은 한 벌이다. 다른 것은 values, StorageClass, Ingress다.
- kind에서 고친 공통 설정을 푸시하면 EKS의 Argo CD도 같은 커밋을 맞출 수 있다.
- 데이터는 여전히 각 클러스터 디스크에만 있다.

여기까지가 멀티 클라우드 준비다. 도구를 새로 도입하는 단계가 아니라, 방금 EKS에 쓴 방식을 세 번째 클러스터에도 반복할 수 있는지 확인하는 단계다.

### 6. GCP를 두 번째 클라우드로 추가한다

완료 조건

- Terraform은 `terraform/gcp`로 AWS 모듈과 따로 둔다. AWS 코드에 `cloud = "gcp"` 분기를 넣지 않는다.
- HCP Terraform workspace `gcp-dev`가 따로 있고, 실행 기록이 AWS workspace와 섞이지 않는다.
- GKE가 하나 생기고, 그 안의 Argo CD가 같은 GitHub `main`을 GKE용 values로 맞춘다.
- 4단계와 같은 순서로 Redis부터 다시 확인한다. AWS에 있는 데이터를 GKE로 복제하지 않는다.
- 회사 연습용 GCP 프로젝트를 쓴다면, 그 프로젝트의 IAM과 결제 권한만 사용한다. 회사의 다른 워크로드와 VPC를 공유하지 않는다.

GCP에서도 기록은 두 층이다. 누가 Terraform을 실행했는지는 HCP Terraform, 프로젝트 안에서 어떤 API가 바뀌었는지는 Cloud Audit Logs다.

## 명령 기록

개발 중 apply는 로컬 Terraform CLI로 한다. 실행과 상태 저장은 HCP Terraform이 한다.

| 남길 내용 | 어디 |
| --- | --- |
| 누가 `plan` / `apply`를 실행했는지, plan 전문, 성공 여부 | HCP Terraform run history. workspace는 `aws-dev`, 이후 `gcp-dev` |
| VPC, 클러스터, IAM이 실제로 바뀌었는지 | AWS CloudTrail, GCP Cloud Audit Logs |
| 클러스터 안 서비스가 어떤 Git 커밋으로 맞춰졌는지 | Argo CD 동기화 이력과 GitHub 커밋 |

실패 run은 알림으로 받고, HCP Terraform drift detection으로 콘솔에서 손으로 만든 변경이 있는지도 본다.

운영에 가까운 변경이 필요해지면 그때 GitHub Pull Request에서 plan을 리뷰하고 머지할 때 apply하는 workflow를 같은 workspace에 추가한다. 개발 초기부터 PR을 강제하지 않는다.

## 비용

비용을 만드는 자원은 연습이 끝난 뒤에도 남아 있는 것들이다.

- EKS, GKE 컨트롤 플레인은 노드를 꺼도 과금된다.
- NAT Gateway, Load Balancer, 디스크는 클러스터와 따로 과금된다.
- Postgres와 Qdrant용 디스크는 클러스터를 지워도 남길 수 있다. 남기면 데이터는 보존되고 비용도 남는다.

1단계의 예산 경보를 클러스터보다 먼저 만든다. 한 클라우드의 개발 클러스터가 뜬 상태에서 다음 클라우드를 만들지 않는다. GCP 단계는 AWS에서 5단계가 끝난 뒤에 시작한다.

## 저장소에 둘 위치

코드를 넣는 시점의 모양만 정해 둔다. 이 문서 단계에서는 디렉터리를 만들지 않는다.

```
terraform/
├── aws/          # VPC, EKS, IAM. HCP Terraform workspace aws-dev
└── gcp/          # VPC, GKE, IAM. HCP Terraform workspace gcp-dev
clusters/
├── kind/         # 지금 ingress, hostPath, 노드 라벨
├── eks/
└── gke/
```

`argocd/`, `airflow/`, `postgres/` 같은 서비스 정의는 지금 자리에 둔다. 클러스터별 차이만 `clusters/`로 뺀다.
