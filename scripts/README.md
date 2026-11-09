# 클러스터 스크립트

`scripts/cluster.sh`는 이 저장소의 kind 클러스터와 서비스를 올리고 내리는 진입점이다. 처음 쓰는 사람은 명령을 외우기 전에, 왜 서비스가 한 층으로 나뉘어 있는지부터 보면 된다.

## 왜 이렇게 나뉘어 있나

이 클러스터에는 역할이 다른 것이 섞여 있다.

- **kind**는 노드다. 맥의 `~/kind-data`를 노드 안에 마운트만 한다.
- **Argo CD**는 설치 도구다. Git의 Application을 클러스터에 맞춘다.
- **storage**는 Jenkins, Redis, Qdrant처럼 파일로 저장하는 서비스의 PV다. PV 객체만 있고 파드는 없다.
- **Postgres**는 실제로 뜨는 공유 데이터베이스다. Airflow, MLflow, Grafana, Superset, LiteLLM이 여기를 쓴다.
- **Jenkins, Airflow 같은 이름**은 테스트하려는 서비스다.

이걸 한 명령에 평평하게 두면, Jenkins만 지우려다 Postgres까지 지우거나, 반대로 Postgres가 없는 클러스터에 Airflow만 올려 Pending에 빠진다. 그래서 명령은 두 층만 안다.

`up kind`는 기반까지만 만든다. kind, Argo CD, Ingress(`infra`), PV(`storage`)다. Postgres는 여기 없다. 파드가 뜨는 데이터베이스를, 쓰는 서비스도 없는데 미리 띄우지 않기 위해서다.

`up airflow`는 목록에서 Airflow의 의존성이 Postgres인 것을 보고, Postgres가 이미 Ready가 아니면 Postgres를 먼저 올린 다음 Airflow를 올린다. 이미 있으면 Airflow만 올린다. Jenkins는 의존성이 비어 있다. Jenkins 데이터는 Postgres가 아니라 `up kind`가 만든 PV에 파일로 저장되기 때문이다.

`down airflow`는 Airflow만 지운다. Postgres는 남겨 둔다. MLflow가 아직 그 데이터베이스를 쓸 수 있기 때문이다. 다른 서비스가 의존성으로 적어 둔 대상은, 그 서비스의 Application이 남아 있으면 삭제를 거절한다.

`down`과 `down kind`만 클러스터 전체를 지운다. 둘은 같은 동작이다. kind를 지우면 그 안의 서비스도 함께 사라지기 때문이다.

## 데이터는 왜 남는가

Postgres, Jenkins, Redis, Qdrant, Neo4j의 파일은 클러스터 안이 아니라 맥의 `~/kind-data`에 있다. kind는 이 폴더를 노드에 연결만 한다. 클러스터 컨테이너를 지워도 폴더는 지워지지 않는다. 스크립트에는 이 경로를 지우는 명령이 없다.

예외가 하나 있다. Airflow 스케줄러와 트리거 로그는 kind 노드 디스크의 `standard` 스토리지에 있다. 이 디스크는 클러스터를 지우면 함께 사라진다. Airflow의 DAG 실행 기록 자체는 Postgres `airflow` 데이터베이스에 있고, 그 파일은 `~/kind-data/postgres`에 남는다.

서비스를 하나만 지운 뒤 다시 올릴 때, PV가 `Released`로 남으면 새 PVC가 예전 디스크에 붙지 못한다. 바인드될 때 기록된 `claimRef`의 UID가 새 PVC와 다르기 때문이다. `down <서비스>`는 해당 PV의 `claimRef`만 비운다. 디스크의 파일은 그대로다.

## 왜 App of Apps를 쓰지 않나

`argocd/application-of-apps.yaml`은 `argocd/` 아래 Application을 전부 자동으로 맞춘다. 자동 동기화가 켜져 있으면 `down jenkins`로 지운 Jenkins를 Git에 파일이 있다는 이유로 다시 만든다.

이 스크립트는 서비스마다 Application 파일을 직접 적용한다. 시작할 때 App of Apps의 자동 동기화만 끈다. App of Apps Application 자체는 지우지 않는다. 지우면 최종자가 자식 Application까지 지울 수 있기 때문이다.

Argo CD가 읽는 매니페스트는 GitHub `main`이다. 로컬에서만 고친 `values.yaml`은 푸시하기 전에는 클러스터에 반영되지 않는다.

## 명령

삭제는 `y` 또는 `Y`를 입력해야 진행된다. Enter는 취소다.

```bash
./scripts/cluster.sh list
./scripts/cluster.sh up kind
./scripts/cluster.sh up jenkins
./scripts/cluster.sh up
./scripts/cluster.sh down jenkins
./scripts/cluster.sh down
```

| 명령 | 동작 |
| --- | --- |
| `up kind` | kind, Argo CD, Ingress, PV. 클러스터가 있으면 그대로 쓰고 기반만 맞춘다 |
| `up <서비스>` | 클러스터가 없으면 에러. 의존성이 Ready가 아니면 먼저 설치하고, 있으면 그 서비스만 설치 |
| `up` | `up kind` 다음에 목록의 모든 서비스 |
| `down <서비스>` | 그 Application과 네임스페이스만 삭제. 공유 DB와 `~/kind-data`는 유지. 다른 서비스가 의존 중이면 거절 |
| `down`, `down kind` | 이름 `kind`인 클러스터만 삭제. `~/kind-data`는 유지. 다른 kind 클러스터는 건드리지 않음 |
| `list` | 등록된 서비스와 의존성 |

웹 화면은 Ingress로 연다. kind가 호스트 80번을 Ingress에 연결해 두었으므로, `/etc/hosts`에 이름이 있으면 `http://jenkins.local`처럼 연다. 이 스크립트는 포트포워딩을 열지 않는다.

```bash
sudo sh -c 'echo "127.0.0.1 argocd.local airflow.local mlflow.local superset.local grafana.local prometheus.local jenkins.local minio.local litellm.local qdrant.local redis.local" >> /etc/hosts'
```

`up kind`만 한 직후 `up jenkins`를 하면 Jenkins만 설치된다. `up airflow`는 Postgres가 없으면 `postgres-storage`를 먼저 설치한다. `up litellm`은 Postgres와 Redis가 없으면 둘 다 먼저 설치한다.

## 지금 등록된 의존성

`scripts/services.conf`가 기준이다.

| 서비스 | 먼저 필요한 것 | 데이터가 남는 곳 |
| --- | --- | --- |
| jenkins, minio, prometheus, qdrant, neo4j, kafka | `up kind`의 PV | `~/kind-data/storage/<이름>` |
| redis | `up kind`의 PV | `~/kind-data/storage/redis` |
| postgres | 없음 | `~/kind-data/postgres` |
| airflow, mlflow, grafana, superset | postgres | 공유 Postgres 안의 같은 이름 데이터베이스 |
| litellm | postgres, redis | Postgres `litellm` 데이터베이스, 캐시는 Redis |
| sample | 없음 | 이미지와 Git. 이 목록의 디스크를 쓰지 않음 |

Kafka 줄 하나에는 Application이 둘이다. `kafka-operator`를 먼저 두고, 그다음 `kafka-cluster`를 둔다. 오퍼레이터가 없으면 Kafka 클러스터 리소스를 처리할 수 없기 때문이다.

## 서비스를 추가하는 방법

스크립트의 `if`를 고치지 않는다. 아래 세 단계면 된다.

1. `argocd/application-<이름>.yaml`을 기존 Application과 같은 형식으로 만든다. `destination.namespace`와 `CreateNamespace=true`를 둔다.
2. 파일로 저장하는 서비스면 `storage/pv-<이름>.yaml`을 추가한다. `storage` Application이 `storage/` 디렉터리를 통째로 동기화하므로, PV 파일을 넣는 것만으로 `up kind` 다음에 포함된다.
3. `scripts/services.conf`에 한 줄을 넣는다.

```text
이름|argocd/application-이름.yaml|ArgoCD에_보일_Application이름|의존성또는-|네임스페이스|PV또는-
```

의존성이 여러 개면 쉼표로 이어 쓴다. `litellm|...|litellm|postgres,redis|litellm|-`처럼이다. Application 이름이 명령 이름과 다르면 세 번째 칸에 실제 이름을 적는다. Postgres 명령은 `postgres`지만 Application 이름은 `postgres-storage`다.

추가한 뒤에는 `./scripts/cluster.sh list`로 줄이 보이는지만 확인하면 된다.
