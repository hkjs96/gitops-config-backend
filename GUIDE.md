# GitOps Config Repo — 로컬 K8s 구축·배포·검증 가이드

> Config Repo 디렉토리 구조 설계 → Helm chart 작성 → Git push → ArgoCD Application 생성 → 환경 분리 배포 → 검증.
> 로컬 Kubernetes(k3d) + GitHub 기반.
>
> - 테스트용 MSA 애플리케이션 구성: [GUIDE-APP.md](./GUIDE-APP.md)
> - ArgoCD 마이그레이션 가이드 (EKS 운영): [GUIDE-EKS.md](./GUIDE-EKS.md)

---

## 1. 아키텍처

```
  App Repo (별도 리포)            Config Repo (이 리포)
  ┌──────────────┐              ┌─────────────────────────────────┐
  │ user-service │              │ apps/                           │
  │ order-service│  이미지 빌드  │  ├── user-service/              │
  │ api-gateway  │  후 tag 변경  │  │   ├── base/  (Helm chart)    │
  └──────┬───────┘              │  │   └── overlays/ dev|stg|prd  │
         │                      │  ├── order-service/              │
         ▼                      │  └── api-gateway/                │
  overlay values.yaml의         └────────────────┬────────────────┘
  image.tag 변경 → git push                      │
                                                  ▼
                                         ┌──────────────┐
                                         │   ArgoCD     │
                                         └──────┬───────┘
                                                │ sync
                                     ┌──────────┴──────────┐
                                     ▼                     ▼
                               ┌──────────┐          ┌──────────┐
                               │  dev NS  │          │  stg NS  │
                               │ AutoSync │          │ Manual   │
                               └──────────┘          └──────────┘
```

### 환경 분리 전략

| 항목 | dev | stg |
|------|-----|-----|
| ArgoCD Sync | Auto (prune + selfHeal) | Manual |
| namespace | `<서비스>-dev` | `<서비스>-stg` |
| Spring profile | `dev` | `stg` |
| 이미지 태그 | `dev-N` | `stg-N` |
| 로컬 port-forward | `18080` | `28080` |

---

## 2. 사전 준비

### 2.1 필수 도구 (macOS)

```bash
brew install git jq kubectl helm argocd
brew install --cask docker

# 로컬 K8s 클러스터 (k3d 사용)
brew install k3d
```

### 2.2 로컬 K8s 클러스터 생성

```bash
k3d cluster create argocd-lab --agents 2
kubectl cluster-info
```

### 2.3 ArgoCD 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
```

### 2.4 ArgoCD 접속

```bash
# 초기 비밀번호
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# 포트포워드 (UI: https://localhost:9081)
kubectl -n argocd port-forward svc/argocd-server 9081:443 &

# CLI 로그인
argocd login localhost:9081 --insecure --username admin --password <PASSWORD>
```

---

## 3. Config Repo 디렉토리 구조

새 서비스를 ArgoCD에 등록하려면 아래 구조로 디렉토리를 만든다.

```
gitops-config/
└── apps/
    └── <서비스명>/
        ├── base/                         # Helm chart (공통)
        │   ├── Chart.yaml
        │   ├── values.yaml               # 기본값
        │   └── templates/
        │       ├── deployment.yaml
        │       ├── service.yaml
        │       └── ingress.yaml
        └── overlays/                     # 환경별 오버라이드
            ├── dev/values.yaml
            ├── stg/values.yaml
            └── prd/values.yaml
```

api-gateway처럼 cross-namespace 라우팅이 필요한 경우:
```
apps/api-gateway/base/templates/
    └── upstream-alias-services.yaml      # ExternalName Service
```

---

## 4. Helm Chart 작성

### 4.1 Chart.yaml

```yaml
apiVersion: v2
name: <서비스명>
type: application
version: 0.1.0
```

### 4.2 base/values.yaml

```yaml
replicaCount: 1

app:
  profile: dev

image:
  repository: <서비스명>          # 로컬: 이미지명, 운영: 레지스트리 URL
  tag: "dev-1"
  pullPolicy: IfNotPresent

imagePullSecrets: []

service:
  name: <서비스명>
  port: 80
  targetPort: 8080

ingress:
  enabled: false
  className: alb
  annotations: {}
  host: ""
```

### 4.3 templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.service.name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.service.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.service.name }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- range . }}
        - name: {{ . }}
        {{- end }}
      {{- end }}
      containers:
        - name: {{ .Values.service.name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "{{ .Values.app.profile }}"
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 10
            periodSeconds: 10
```

### 4.4 templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.service.name }}
spec:
  selector:
    app: {{ .Values.service.name }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
```

### 4.5 templates/ingress.yaml

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Values.service.name }}
  annotations:
    {{- range $key, $val := .Values.ingress.annotations }}
    {{ $key }}: "{{ $val }}"
    {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Values.service.name }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

### 4.6 Overlay values (환경별)

overlay는 base values.yaml에서 바꿀 값만 작성한다.

```yaml
# overlays/dev/values.yaml
app:
  profile: dev
image:
  tag: "dev-1"
```

```yaml
# overlays/stg/values.yaml
app:
  profile: stg
image:
  tag: "stg-1"
replicaCount: 1
```

```yaml
# overlays/prd/values.yaml
app:
  profile: prd
image:
  tag: "prd-1"
replicaCount: 2
```

### 4.7 api-gateway: ExternalName Service (cross-namespace DNS)

api-gateway는 자신의 namespace에서 `http://user-service:80`으로 라우팅하지만,
실제 Pod는 별도 namespace에 있다. ExternalName Service로 해결.

**base/templates/upstream-alias-services.yaml**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.upstreams.userService.name }}
spec:
  type: ExternalName
  externalName: "{{ .Values.upstreams.userService.name }}.{{ .Values.upstreams.userService.namespace }}.svc.cluster.local"
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.upstreams.orderService.name }}
spec:
  type: ExternalName
  externalName: "{{ .Values.upstreams.orderService.name }}.{{ .Values.upstreams.orderService.namespace }}.svc.cluster.local"
```

**base/values.yaml 추가분:**
```yaml
upstreams:
  userService:
    name: user-service
    namespace: user-service-dev
  orderService:
    name: order-service
    namespace: order-service-dev
```

**overlay에서 namespace 오버라이드:**
```yaml
# overlays/stg/values.yaml
upstreams:
  userService:
    namespace: user-service-stg
  orderService:
    namespace: order-service-stg
```

---

## 5. Git Push

```bash
git add -A
git commit -m "feat: add helm charts for user-service, order-service, api-gateway"
git push origin main
```

---

## 6. Docker 이미지 준비 (로컬)

로컬 k3d 환경에서는 레지스트리 없이 이미지를 직접 클러스터에 import한다.

```bash
# App Repo에서 빌드
docker build --network=host -t user-service:dev-1 ./user-service
docker build --network=host -t order-service:dev-1 ./order-service
docker build --network=host -t api-gateway:dev-1 ./api-gateway

# stg 태그
docker tag user-service:dev-1 user-service:stg-1
docker tag order-service:dev-1 order-service:stg-1
docker tag api-gateway:dev-1 api-gateway:stg-1

# k3d 클러스터에 import
k3d image import \
  user-service:dev-1 user-service:stg-1 \
  order-service:dev-1 order-service:stg-1 \
  api-gateway:dev-1 api-gateway:stg-1 \
  -c argocd-lab
```

---

## 7. ArgoCD Application 생성

### 7.1 Git Repo 연결

```bash
# CLI
argocd repo add https://github.com/<GITHUB_ID>/<CONFIG_REPO>.git \
  --username <GITHUB_ID> \
  --password <GITHUB_PAT> \
  --insecure-skip-server-verification

# 또는 Kubernetes Secret (TLS 문제 해결용)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-gitops-config
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/<GITHUB_ID>/<CONFIG_REPO>.git
  username: <GITHUB_ID>
  password: <GITHUB_PAT>
  insecure: "true"
EOF
```

> TLS 문제 시: `kubectl -n argocd rollout restart deploy argocd-repo-server`

### 7.2 ArgoCD UI에서 Application 생성

ArgoCD UI에서 각 서비스별·환경별 Application을 생성한다.

| 필드 | dev 예시 | stg 예시 |
|------|----------|----------|
| Application Name | `user-service-dev` | `user-service-stg` |
| Project | `default` | `default` |
| Sync Policy | `Automatic` (Prune ✓, Self Heal ✓) | `Manual` |
| Repository URL | `https://github.com/<ID>/<REPO>.git` | (동일) |
| Revision | `HEAD` | `HEAD` |
| Path | `apps/user-service/base` | `apps/user-service/base` |
| Helm Values Files | `../overlays/dev/values.yaml` | `../overlays/stg/values.yaml` |
| Cluster URL | `https://kubernetes.default.svc` | (동일) |
| Namespace | `user-service-dev` | `user-service-stg` |
| Auto-Create Namespace | ✓ | ✓ |

> 3개 서비스 × 2개 환경 = 총 6개 Application.
> `order-service`, `api-gateway`도 동일 패턴으로 path/namespace만 변경.

### 7.3 (대안) kubectl apply — 빠른 테스트용

```bash
kubectl apply -f argocd/apps-dev.yaml    # dev 3개 (AutoSync)
kubectl apply -f argocd/apps-stg.yaml    # stg 3개 (ManualSync)
```

### 7.4 stg 수동 Sync

```bash
argocd app sync user-service-stg
argocd app sync order-service-stg
argocd app sync api-gateway-stg
```

### 7.5 배포 상태 확인

```bash
argocd app list
```

```
NAME                  STATUS  HEALTH   SYNCPOLICY
user-service-dev      Synced  Healthy  Auto-Prune
order-service-dev     Synced  Healthy  Auto-Prune
api-gateway-dev       Synced  Healthy  Auto-Prune
user-service-stg      Synced  Healthy  Manual
order-service-stg     Synced  Healthy  Manual
api-gateway-stg       Synced  Healthy  Manual
```

---

## 8. 검증

### 8.1 Port-Forward

```bash
kubectl -n api-gateway-dev port-forward svc/api-gateway 18080:80 &
kubectl -n api-gateway-stg port-forward svc/api-gateway 28080:80 &
```

### 8.2 API 호출

```bash
# dev
curl http://localhost:18080/users   # env: "dev"
curl http://localhost:18080/orders

# stg
curl http://localhost:28080/users   # env: "stg"
curl http://localhost:28080/orders
```

---

## 9. "dev만 변경 → stg 불변" 검증

### 9.1 새 이미지 빌드 & import

```bash
docker build --network=host -t user-service:dev-2 ./user-service
docker build --network=host -t order-service:dev-2 ./order-service
k3d image import user-service:dev-2 order-service:dev-2 -c argocd-lab
```

### 9.2 dev overlay tag만 변경

```yaml
# apps/user-service/overlays/dev/values.yaml
image:
  tag: "dev-2"

# apps/order-service/overlays/dev/values.yaml
image:
  tag: "dev-2"
```

### 9.3 Git push

```bash
git add -A
git commit -m "chore: bump dev tags to dev-2"
git push origin main
```

### 9.4 결과

```bash
# dev — 변경 반영됨 ✅ (AutoSync)
curl http://localhost:18080/users   # 새 데이터 포함

# stg — 변경 없음 ✅ (stg-1 그대로)
curl http://localhost:28080/users   # 기존 데이터 유지
```

---

## 10. CI 가드 스크립트

dev overlay만 자동 배포 허용, stg/prd 변경은 별도 PR + 승인 강제.

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE_REF="${BASE_REF:-origin/main}"
CHANGED="$(git diff --name-only "${BASE_REF}...HEAD" || true)"
[[ -z "${CHANGED}" ]] && echo "[OK] 변경 없음" && exit 0

ALLOWED='^apps/.*/overlays/dev/values\.ya?ml$'
DENIED="$(echo "${CHANGED}" | grep -Ev "${ALLOWED}" || true)"
[[ -n "${DENIED}" ]] && echo "[DENY] stg/prd 변경 감지" && echo "${DENIED}" && exit 1
echo "[OK] dev overlay만 변경됨"
```

---

## 11. 참고: ApplicationSet

| 파일 | 용도 |
|------|------|
| `argocd/applicationset-local.yaml` | 로컬 k3d dev+stg 동시 테스트 |
| `argocd/applicationset.yaml` | 멀티클러스터 EKS용 (dev=Auto, stg+prd=Manual) |
