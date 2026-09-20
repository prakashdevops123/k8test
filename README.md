# k8test — Helm + Argo CD + Minikube GitOps lab

Ek chhoti NGINX application jise **Git se** deploy kiya jata hai: Helm chart
desired state define karta hai, GitHub Actions usko validate karta hai, aur
Argo CD usko local Minikube cluster mein **pull** karke apply karta hai.

Yeh repo seekhne ke liye hai — Git, GitOps, Helm, Argo CD sync/reconciliation,
rollouts, rollback aur troubleshooting.

---

## Architecture

```
  aap                     GitHub (yeh repo)
   │                            │
   │ git push ───────────────►  │
   │                       ┌────┴─────┐
   │                       │ Actions  │  helm lint + helm template
   │                       │   CI     │  + kubeconform
   │                       └────┬─────┘  (VALIDATE karta hai, deploy NAHI)
   │                            │
   │                            │ Argo CD har ~3 min PULL karta hai
   ╔════════════════════════════╪══════════════════════════════╗
   ║ MINIKUBE                   ▼                              ║
   ║  ns: argocd        ┌────────────────┐                     ║
   ║                    │ repo-server    │ git clone +         ║
   ║                    │                │ helm template       ║
   ║                    │ app-controller │ desired vs live     ║
   ║                    │ server (UI)    │ compare + apply     ║
   ║                    └───────┬────────┘                     ║
   ║  ns: nginx-lab             │ apply                        ║
   ║                    ┌───────▼────────┐                     ║
   ║                    │ Deployment (3) │──► nginx pods       ║
   ║                    │ Service        │                     ║
   ║                    │ ConfigMap      │                     ║
   ║                    └────────────────┘                     ║
   ╚═══════════════════════════════════════════════════════════╝
```

**Ek zaroori baat:** CI cluster ko **kabhi touch nahi karta**. GitHub-hosted
runner internet par chalta hai; Minikube aapke laptop par `127.0.0.1` hai —
runner wahan pahunch hi nahi sakta. CI *validate* karta hai, Argo CD *pull*
karta hai. Isi wajah se koi kubeconfig ya cluster credential Git mein nahi hai.

---

## Repo structure

```
charts/nginx/                    Helm chart = desired state
  Chart.yaml                     chart identity (version vs appVersion)
  values.yaml                    saare knobs — YAHI file aap badlenge
  templates/
    _helpers.tpl                 naam + label helpers (DRY)
    deployment.yaml              pods, probes, resources, configmap mount
    service.yaml                 ClusterIP
    configmap.yaml               custom homepage
    NOTES.txt                    install ke baad instructions
argocd/
  application-nginx.yaml         Argo CD Application (GitOps wiring)
.github/workflows/
  helm-validate.yml              CI: lint + template + kubeconform
```

---

## Setup (zero se)

### 1. Prerequisites

| Tool | Version (tested) |
|---|---|
| Ubuntu | 24.04 |
| Docker | 29.7.2 (rootless) |
| minikube | v1.39.0 |
| kubectl | v1.36.3 |
| Helm | v3.16.4 |
| Argo CD | v3.5.3 (server + CLI) |
| kubeconform | v0.8.0 |

Rootless Docker use ho raha hai, isliye har shell mein:

```bash
export DOCKER_HOST=unix:///run/user/1000/docker.sock   # ~/.bashrc mein hai
```

### 2. Cluster

Rootless Docker `dockerd` runtime support nahi karta, isliye `containerd`:

```bash
minikube config set rootless true
minikube start --driver=docker --container-runtime=containerd
minikube addons enable metrics-server
kubectl get nodes
```

### 3. Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side=true \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
```

`--server-side=true` **zaroori** hai — warna ApplicationSet CRD par
`metadata.annotations: Too long` error aata hai (256 KB limit).

### 4. UI

```bash
kubectl port-forward -n argocd svc/argocd-server 8081:443
# https://localhost:8081  (self-signed cert -> Advanced -> Proceed)
```

Initial password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Password badalne ke baad us secret ko **delete kar do** — woh sirf bootstrap
convenience hai. Password kabhi Git mein mat daalo (yeh repo public hai).

Agar woh secret gayab ho jaye, password reset:

```bash
NEW='apna-password'
HASH=$(htpasswd -nbBC 10 "" "$NEW" | tr -d ':\n' | sed 's/\$2y\$/\$2a\$/')
kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
kubectl -n argocd rollout restart deploy/argocd-server
```

**Ya password use hi mat karo** — CLI ka core mode seedha Kubernetes API se
baat karta hai:

```bash
kubectl config set-context --current --namespace=argocd
argocd app list --core
```

### 5. Application deploy

```bash
kubectl apply -f argocd/application-nginx.yaml
argocd app sync nginx-lab --core
```

### 6. App kholo

```bash
kubectl port-forward -n nginx-lab svc/nginx-lab 8080:80
# http://localhost:8080
```

---

## Rozana ke commands

```bash
# status
argocd app get nginx-lab --core
kubectl get application nginx-lab -n argocd

# Git dobara padho (cluster NAHI badlega)
argocd app get nginx-lab --core --refresh
argocd app get nginx-lab --core --hard-refresh     # Redis cache bhi bypass

# desired vs live
argocd app diff nginx-lab --core

# apply karo
argocd app sync nginx-lab --core
argocd app sync nginx-lab --core --dry-run         # kuch apply nahi hoga

# app
kubectl get pods,svc,deploy -n nginx-lab
kubectl rollout status deploy/nginx-lab -n nginx-lab
kubectl top pods -n nginx-lab

# chart locally validate (wahi jo CI karta hai)
helm lint charts/nginx --strict
helm template nginx-lab charts/nginx --namespace nginx-lab
helm template nginx-lab charts/nginx | kubeconform -kubernetes-version 1.37.0 -strict -summary -
```

---

## Concepts

### Sync vs Health — do ALAG cheezein

| Sync | Health | Matlab |
|---|---|---|
| `OutOfSync` | `Missing` | Git mein hai, cluster mein nahi |
| `OutOfSync` | `Healthy` | Chal raha hai, par Git se alag version |
| `Synced` | `Healthy` | Sab theek |
| `Synced` | `Progressing` | Apply ho gaya, rollout chal raha |
| `Synced` | `Degraded` | Git ke mutabik apply hua, **par app toota hua hai** |

`Sync` = "Git match karta hai?" · `Health` = "app kaam kar raha hai?"
Ek `Synced` app bilkul toot sakti hai — agar galti Git mein hi ho.

### refresh vs sync

- **refresh** — Git dobara padho aur compare karo. **Cluster nahi badalta.**
- **hard refresh** — Redis cache bhi bypass, `helm template` dobara chalao.
- **sync** — farak actually mita do. **Yeh cluster badalta hai.**

### prune aur selfHeal

- **prune** — Git se resource hataya to cluster se bhi delete. Default `false`,
  kyunki ek galat commit poora namespace uda sakta hai.
- **selfHeal** — koi `kubectl scale/edit` kare to Argo CD usko Git wali state
  par wapas kheench leta hai. Powerful, par emergency mein aapka manual fix
  bhi undo kar dega.

Is repo mein dono **on** hain (`argocd/application-nginx.yaml`), isliye chart
changes PR se jaane chahiye.

### Argo CD `helm install` NAHI chalata

Woh `helm template` chala kar plain YAML banata hai aur usko apply karta hai.

| | Helm direct | Argo CD |
|---|---|---|
| State kahan | cluster Secret (`sh.helm.release.*`) | **Git** |
| Rollback | `helm rollback` | `git revert` + sync |
| History | `helm history` | `git log` |
| `helm list` | dikhta hai | **nahi dikhta** |

Isliye is setup mein `helm rollback` **`Error: release: not found`** dega.

### Deployment selector immutable hai

`_helpers.tpl` do alag label sets banata hai:

```
selectorLabels = name + instance                      <- SIRF yeh selector mein
labels         = selectorLabels + chart + version + managed-by + component
```

Agar `version` selector mein hota, to image tag badalne par
`field is immutable` error aata. Yeh production mein common galti hai.

### `checksum/config` annotation

ConfigMap badalne se pods apne aap restart **nahi** hote — woh purani file
serve karte rehte hain. `deployment.yaml` ConfigMap ka sha256 pod template
annotation mein daal deta hai, to ConfigMap badli → hash badla → rolling
restart.

---

## CI — teen layer ki validation

| Layer | Kya pakadta hai |
|---|---|
| `helm lint --strict` | Chart structure, template parse errors |
| `helm template` | Rendering, variable typos |
| `kubeconform` | **Invalid values** — jo upar ke dono miss karte hain |

`helm lint` akela kaafi **nahi** hai. Proof:

```yaml
replicaCount: "three"     # string, integer nahi
```

- `helm lint --strict` → **PASS**
- `helm template` → **PASS**, `replicas: three` render kar deta hai
- `kubeconform` → **FAIL**: `at '/spec/replicas': got string, want integer`

Aur kubeconform bhi sab kuch nahi pakadta — woh **schema** check karta hai,
semantic rules nahi. Jaise `requests: 64Gi` with `limits: 128Mi` CI paar kar
jata hai, par API server reject karta hai:
`must be less than or equal to memory limit`.

### Production pipeline kaise alag hoti

Yeh lab CI sirf validate karta hai. Production mein aage yeh hota:

1. **Build** — app ka container image banao, immutable tag do (`git-<sha>`,
   `latest` kabhi nahi)
2. **Scan** — image vulnerability scan (Trivy/Grype), SBOM
3. **Sign** — cosign se sign karo, cluster mein policy se verify karao
4. **Push** — registry par bhejo
5. **Promote** — CI ek **config repo** mein image tag badal kar commit/PR
   karta hai (yeh "image updater" pattern hai)
6. **Deploy** — Argo CD us commit ko dekh kar deploy karta hai

Dhyan do: step 6 mein bhi CI cluster ko touch nahi karta. Aur aksar **app repo
aur config repo alag** hote hain, taaki app ka code push deploy trigger na kare.

---

## Troubleshooting

| Lakshan | Wajah | Diagnose |
|---|---|---|
| `ImagePullBackOff` | image/tag exist nahi karta, ya registry auth | `kubectl describe pod` → Events |
| `Pending` | node par resources nahi, ya nodeSelector match nahi | `describe pod` → `FailedScheduling` |
| `CrashLoopBackOff` + exit 137 | liveness probe fail → SIGKILL | `describe pod` → `Liveness probe failed` |
| `Synced` par app down | galti **Git mein** hai | `helm template` locally chalao |
| `SyncFailed` | API server ne reject kiya | `argocd app get` → `operationState.message` |
| `OutOfSync` khud aa gaya | kisi ne `kubectl` se drift kiya | `argocd app diff` |
| `annotations: Too long` | client-side apply + bada CRD | `--server-side=true` |
| `release: not found` | Argo CD ne helm install nahi kiya | `git revert` use karo |
| `lost connection to pod` | port-forward flaky hai | dobara chalao (loop mein) |
| UI `ERR_CERT_AUTHORITY_INVALID` | self-signed cert | Proceed / `--insecure` |

### Diagnosis ka order

```bash
kubectl get pods -n nginx-lab                       # 1. lakshan
kubectl describe pod <pod> -n nginx-lab             # 2. Events = asli clue
kubectl logs <pod> -n nginx-lab                     # 3. app kya keh raha hai
kubectl get deploy nginx-lab -n nginx-lab -o json | jq '.status.conditions'
argocd app get nginx-lab --core -o json | jq '.status.operationState'
```

---

## Exercises

| # | Exercise | Seekh |
|---|---|---|
| 1 | `replicaCount` badlo, sync karo | OutOfSync → Synced ka basic loop |
| 2 | Image tag badlo | RollingUpdate: naya RS up, purana down, zero downtime |
| 3 | PR banao | CI PR par chalta hai, deploy nahi karta |
| 4 | Chart todo | `helm lint` syntax pakadta hai; values `kubeconform` pakadta hai |
| 5 | OutOfSync banao, manual sync | `--dry-run`, aur sirf badla resource OutOfSync hota hai |
| 6 | Drift + self-heal | manual mode batata hai; automated mode **theek** karta hai (~3s) |
| 7 | `helm rollback` vs `git revert` | Argo CD ke saath helm rollback kaam nahi karta |
| 8 | Failures diagnose karo | ImagePullBackOff, Pending, probe fail, SyncFailed |
| 9 | Safe rollback | `git revert` — history rewrite nahi, forward-only |
| 10 | Blue-green / canary | neeche dekho |

### Exercise 10 — progressive delivery

**Basic Argo CD progressive delivery NAHI deta.** Woh Git ki state apply karta
hai; traffic shifting uska kaam nahi hai. Kubernetes `Deployment` khud sirf do
strategies deta hai:

- `RollingUpdate` (default) — purane pods thode-thode replace hote hain
- `Recreate` — sab maar do, phir naye banao (downtime hota hai)

**Blue-green** — do poore environments (blue = purana, green = naya). Naya
100% ready hone ke baad traffic ek saath switch hota hai. Rollback turant hai
(wapas blue par). Cost: thodi der ke liye **do guna resources**.

**Canary** — naya version ko **thoda sa** traffic (5% → 25% → 50% → 100%),
har step par metrics dekhte hue. Blast radius chhota rehta hai. Iske liye
traffic splitting chahiye (service mesh ya ingress) aur automated analysis.

**Argo Rollouts** (`argoproj/argo-rollouts`, latest `v1.10.0`) — yeh ek
**alag project** hai, Argo CD ka hissa nahi. Woh `Rollout` naam ka CRD deta
hai jo `Deployment` ki jagah use hota hai:

```yaml
kind: Rollout
spec:
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: {duration: 5m}
        - analysis: {templates: [{templateName: success-rate}]}
        - setWeight: 50
```

Argo CD `Rollout` object ko waise hi deploy karega jaise aur kuch bhi —
progressive logic **Rollouts controller** chalata hai, Argo CD nahi. Dono
saath kaam karte hain, par ek doosre ki jagah nahi lete.

Is lab ko aage badhana ho to: Argo Rollouts install karo, `Deployment` ko
`Rollout` mein badlo, aur canary steps add karo. Real canary analysis ke liye
Prometheus bhi chahiye hoga.

---

## Cleanup

⚠️ Har command se **pehle padho**. Neeche ke pehle teen sirf lab ke resources
hatate hain; aakhri wala **poora cluster** delete karta hai.

```bash
# 1. sirf app (Argo CD chalta rahega)
#    finalizer ki wajah se App delete karne par uske resources bhi jayenge
kubectl delete -f argocd/application-nginx.yaml
kubectl delete namespace nginx-lab

# 2. Argo CD hatao
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io

# 3. addon
minikube addons disable metrics-server
```

```bash
# 4. POORA CLUSTER delete -- yeh sab kuch mita dega,
#    including koi bhi doosra kaam jo is cluster mein ho
minikube delete
```

Pehle hamesha check karo ki cluster mein aur kya chal raha hai:

```bash
kubectl get all -A | grep -vE "kube-system|kube-public|kube-node-lease"
```

---

## Security notes

- Yeh repo **public** hai. Koi token, password, ya kubeconfig kabhi commit
  mat karo. Ek baar push ho gaya to Git history mein hamesha rehta hai —
  force-push se bhi nahi jata, kyunki crawlers pehle hi utha chuke hote hain.
- Argo CD ko is repo ke liye **koi credential nahi chahiye** — public repo
  anonymously padha jata hai.
- CI mein `permissions: contents: read` hai. Cluster credentials CI mein
  bhejna Argo CD ke pull model ka poora faayda khatam kar deta hai.
- GitHub token banao to **fine-grained** banao: sirf yeh repo, sirf
  `Contents: write`, expiry ke saath. Classic PAT aksar poore account par
  full access deta hai — leak hone par `delete_repo` aur `admin:public_key`
  ka matlab hai repos delete + permanent SSH backdoor.
