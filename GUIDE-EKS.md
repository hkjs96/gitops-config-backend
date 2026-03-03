# ArgoCD 마이그레이션 가이드

> 기존 CD에서 ArgoCD(GitOps) 기반으로 전환하기 위한 가이드.
> Config Repo 구성 → ArgoCD 설치 → Repo 연결 → Application 등록 → 환경 분리 배포.

### 플레이스홀더

| 플레이스홀더 | 설명 |
|-------------|------|
| `<고객사저장소URL>` | Config Repo Git URL |
| `<고객사레지스트리>` | 기존 Docker Registry (Nexus 등) |
| `<고객사도메인>` | 서비스 Ingress 도메인 |

---

## 1. 변경 개요

```
  [기존]                              [ArgoCD 전환 후]
  CI에서 빌드 → CD에서 직접 배포       CI에서 빌드 → Config Repo tag 갱신 → ArgoCD가 배포

  App Repo ──CI──▶ 클러스터            App Repo ──CI──▶ Nexus (이미지)
                                                   └──▶ Config Repo (tag 갱신)
                                                              │
                                                        ArgoCD 감시
                                                              │
                                                         K8s 클러스터
```

핵심 변경점:
- CI는 이미지 빌드/푸시까지만 담당 (기존과 동일)
- CD(배포)는 ArgoCD가 Config Repo를 감시하여 수행
- 배포 = Config Repo의 `image.tag` 변경 + git push

---

## 2. Config Repo 구조

기존 서비스별로 아래 구조를 만든다.

```
<config-repo>/
└── apps/
    └── <서비스명>/
        ├── base/
        │   ├── Chart.yaml
        │   ├── values.yaml           # 공통 기본값
        │   └── templates/
        │       ├── deployment.yaml
        │       ├── service.yaml
        │       └── ingress.yaml
        └── overlays/
            ├── dev/values.yaml       # dev 환경 오버라이드
            ├── stg/values.yaml
            └── prd/values.yaml
```

---

## 3. Helm Chart 작성

### 3.1 Chart.yaml

```yaml
apiVersion: v2
name: <서비스명>
type: application
version: 0.1.0
```

### 3.2 base/values.yaml

```yaml
replicaCount: 1

app:
  profile: dev

image:
  repository: <고객사레지스트리>/<서비스명>
  tag: "latest"
  pullPolicy: Always

imagePullSecrets:
  - registry-cred

service:
  name: <서비스명>
  port: 80
  targetPort: 8080

ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/health
  host: ""
```

### 3.3 templates/deployment.yaml

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

### 3.4 templates/service.yaml

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

### 3.5 templates/ingress.yaml

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

### 3.6 Overlay values (환경별)

overlay는 base에서 바꿀 값만 작성한다.

```yaml
# overlays/dev/values.yaml
app:
  profile: dev
image:
  tag: "dev-a1b2c3d"
ingress:
  host: <서비스명>-dev.<고객사도메인>
```

```yaml
# overlays/stg/values.yaml
app:
  profile: stg
image:
  tag: "stg-1.0.0"
replicaCount: 1
ingress:
  host: <서비스명>-stg.<고객사도메인>
```

```yaml
# overlays/prd/values.yaml
app:
  profile: prd
image:
  tag: "1.0.0"
replicaCount: 2
ingress:
  host: <서비스명>.<고객사도메인>
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
```

---

## 4. ArgoCD 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
```

초기 비밀번호:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## 5. Config Repo 연결

```bash
argocd repo add <고객사저장소URL> \
  --username <GIT_USER> \
  --password <GIT_PAT>
```

자체 서명 인증서 환경:
```bash
argocd repo add <고객사저장소URL> \
  --username <GIT_USER> \
  --password <GIT_PAT> \
  --insecure-skip-server-verification
```

---

## 6. Application 등록

### 6.1 ArgoCD UI에서 생성

| 필드 | dev | stg | prd |
|------|-----|-----|-----|
| Name | `<서비스명>-dev` | `<서비스명>-stg` | `<서비스명>-prd` |
| Sync Policy | Automatic (Prune ✓, Self Heal ✓) | Manual | Manual |
| Repo URL | `<고객사저장소URL>` | (동일) | (동일) |
| Path | `apps/<서비스명>/base` | (동일) | (동일) |
| Helm Values | `../overlays/dev/values.yaml` | `../overlays/stg/values.yaml` | `../overlays/prd/values.yaml` |
| Namespace | `<서비스명>-dev` | `<서비스명>-stg` | `<서비스명>-prd` |
| Auto-Create NS | ✓ | ✓ | ✓ |

### 6.2 ApplicationSet (서비스가 많을 때)

서비스 추가 시 `elements`에 한 줄만 추가하면 자동 확장된다.

```yaml
# dev — AutoSync
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: msa-apps-dev
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - serviceName: user-service
          - serviceName: order-service
          - serviceName: api-gateway
  template:
    metadata:
      name: "{{ .serviceName }}-dev"
    spec:
      project: default
      source:
        repoURL: <고객사저장소URL>
        targetRevision: HEAD
        path: "apps/{{ .serviceName }}/base"
        helm:
          valueFiles:
            - "../overlays/dev/values.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ .serviceName }}-dev"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

```yaml
# stg + prd — Manual Sync
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: msa-apps-stg-prd
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - list:
              elements:
                - serviceName: user-service
                - serviceName: order-service
                - serviceName: api-gateway
          - list:
              elements:
                - env: stg
                - env: prd
  template:
    metadata:
      name: "{{ .serviceName }}-{{ .env }}"
    spec:
      project: default
      source:
        repoURL: <고객사저장소URL>
        targetRevision: HEAD
        path: "apps/{{ .serviceName }}/base"
        helm:
          valueFiles:
            - "../overlays/{{ .env }}/values.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ .serviceName }}-{{ .env }}"
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
```

---

## 7. 배포 흐름 (기존 CD → ArgoCD)

### 기존

```
CI 빌드 → CI/CD가 kubectl apply 또는 helm upgrade로 직접 배포
```

### ArgoCD 전환 후

```
CI 빌드 → 이미지 push (기존과 동일)
        → Config Repo overlay의 image.tag 갱신 + git push (추가)
        → ArgoCD가 감지하여 자동/수동 배포
```

CI 파이프라인에서 변경되는 부분은 기존 배포 단계를 아래로 교체:

```bash
# 기존 배포 단계 제거 후, 아래로 대체
git clone <고객사저장소URL> config-repo
cd config-repo
sed -i "s/tag: .*/tag: \"dev-${CI_COMMIT_SHORT_SHA}\"/" \
  apps/<서비스명>/overlays/dev/values.yaml
git add -A
git commit -m "ci: bump <서비스명> dev tag to dev-${CI_COMMIT_SHORT_SHA}"
git push
```

### 환경별 배포 정책

| 환경 | 트리거 | ArgoCD Sync |
|------|--------|-------------|
| dev | CI가 tag 자동 갱신 | Auto |
| stg | MR로 tag 변경 → 승인 → merge | Manual Sync |
| prd | MR로 tag 변경 → 승인 → merge | Manual Sync |

---

## 8. 체크리스트

- [ ] Config Repo 생성 및 Helm chart 구성 완료
- [ ] ArgoCD 설치 완료
- [ ] ArgoCD에 Config Repo 연결됨
- [ ] Application 등록 완료 (dev=Auto, stg/prd=Manual)
- [ ] CI 파이프라인에서 기존 배포 단계 → Config Repo tag 갱신으로 변경
- [ ] dev 배포 자동 동작 확인
- [ ] stg/prd Manual Sync 동작 확인
