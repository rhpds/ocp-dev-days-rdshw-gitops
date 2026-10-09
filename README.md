# OCP Dev Days Roadshow - GitOps

Helm charts and ArgoCD manifests for the OpenShift Developer Experience workshop.

## Architecture Overview

This workshop uses a multi-tenant model on a shared OpenShift cluster. Each participant (tenant) gets isolated resources provisioned on-demand, including a Parasol Insurance application, CI/CD pipelines, and a Developer Hub catalog entry.

### Cluster-Level Components

Deployed once via the **app-of-apps** pattern (`cluster/app-of-apps/`):

| Component | Chart Path | Description |
|-----------|-----------|-------------|
| Vault | `cluster/vault/` | HashiCorp Vault for secrets management |
| External Secrets | `cluster/external-secrets/` | Syncs Vault secrets to Kubernetes Secrets |
| GitLab | `cluster/gitlab/` | Source code hosting (repos imported from GitHub) |
| Quay | `cluster/quay/` | Container image registry |
| OpenShift Pipelines | `cluster/openshift-pipelines/` | Tekton operator |
| Dev Spaces | `cluster/devspaces/` | Cloud development environments |
| OpenVSX | `cluster/openvsx/` | VS Code extension registry for Dev Spaces |
| SonarQube | `cluster/sonarqube/` | Code quality analysis |
| AMQ Streams | `cluster/amq-streams/` | Kafka operator |
| Developer Hub Prereqs | `cluster/developer-hub-prereqs/` | RHDH operator (v1.9) + SA token writer |
| Developer Hub | `cluster/developer-hub/` | Backstage CR, app-config, RBAC, plugins |
| Tenant Prereqs | `cluster/tenant-prereqs/` | Shared tenant RBAC, clusterinterceptors CRB |

### Tenant Provisioning

Each tenant is provisioned by the RHDP platform running Ansible workloads defined in [agnosticv](https://github.com/rhpds/agnosticv). The flow:

1. **Keycloak user** created in the `sso` realm, added to the `users` group
2. **ArgoCD AppProject** created (`appproject-<username>`) restricting deployments to `<username>-*` namespaces
3. **GitOps bootstrap** Application created, which deploys the tenant chart (`tenant/bootstrap/`)

The tenant bootstrap chart (`tenant/bootstrap/`) runs a Job that:

- Creates the user in GitLab and Quay
- **Imports** (not forks) `parasol-insurance` and `parasol-insurance-manifests` repos from the `parasol` group into the user's GitLab namespace
- Sets repos to **public** visibility (ArgoCD has no GitLab credentials)
- Unprotects the `main` branch (mirror push carries protection)
- Templates `catalog-info.yaml` with the user's GUID and cluster subdomain
- Commits and pushes the templated catalog-info

The tenant parasol-insurance chart (`tenant/parasol-insurance-tenant/`) creates:

- **Namespaces**: `<username>-dev`, `<username>-build`, `<username>-prod`
- **ArgoCD Applications**: `<username>-dev`, `<username>-prod` (deploy the app), `<username>-build` (deploy the CI/CD pipeline)
- Kafka topic, resource quotas, RBAC

## Developer Hub (RHDH)

### Catalog Entity Model

```
Shared (visible to all users):
  Resources: kafka-cluster, llm-inference-server
  Templates: Parasol Insurance Development Environment
  Groups: users, admins
  Users: (synced from Keycloak)

Per-user (visible only to owner via RBAC):
  System: parasol-insurance-<username>
  API: parasol-insurance-api-<username>
  Component: parasol-insurance-<username>
    - From catalog-info.yaml in user's parasol-insurance GitLab repo
    - Component and API reference the user's System
    - Annotations link to user's ArgoCD apps, K8s namespaces, pipelines

Per-dev-environment (visible only to owner via RBAC):
  Component: parasol-insurance-dev-<username>
    - From catalog-info.yaml in the gitops repo created by the software template
    - References the user's System
```

### RBAC Model

| Role | Permissions | Assigned To |
|------|------------|-------------|
| `role:default/admin` | Full catalog CRUD (unrestricted) | `group:default/admins` |
| `role:default/developer` | Catalog read (conditional) | `group:default/users` |
| `role:default/scaffolder_execute` | Template execution | `group:default/users`, `group:default/admins` |
| `role:default/plugins` | Kubernetes, Tekton, ArgoCD, Lightspeed | `group:default/users`, `group:default/admins` |

The `developer` role has **conditional read policies**:

- **Components, Systems, APIs**: users can only see entities they own (`IS_ENTITY_OWNER`)
- **Shared types** (Template, Group, User, Location, Domain, Resource): visible to all
- **Update/Delete**: only on owned entities

### Kubernetes Resource Labeling

For RHDH topology, CI, and Kubernetes views to work correctly, all resources must have:

```yaml
# On ALL resource metadata (Deployment, Service, Route, DB, etc.)
labels:
  app.kubernetes.io/name: parasol-insurance-<username>    # Per-user filtering
  app.kubernetes.io/part-of: parasol-insurance-<env>       # Topology grouping
  app.openshift.io/runtime: quarkus                        # Icon (or postgresql for DB)

# On PipelineRun templates (TriggerTemplate)
labels:
  app.kubernetes.io/name: parasol-insurance-<username>     # Tekton plugin matching
```

Catalog entity annotations that reference these:

```yaml
annotations:
  backstage.io/kubernetes-id: parasol-insurance-<username>
  backstage.io/kubernetes-label-selector: "app.kubernetes.io/name=parasol-insurance-<username>"
  janus-idp.io/tekton: parasol-insurance
  argocd/app-name: <username>-dev
```

> [!IMPORTANT]
> Do NOT use `backstage.io/kubernetes-namespace`. The Kubernetes plugin uses a cluster-wide ServiceAccount token and filters by label selector. Setting a namespace would limit visibility to one namespace, missing resources in build/prod.

> [!IMPORTANT]
> Labels must be on resource **metadata** (not just pod templates). The Kubernetes plugin fetches Deployments, Services, Routes etc. by label — if only pod templates have the label, only pods show up in the UI.

## Software Template: Dev Environment

The "Parasol Insurance Development Environment" template creates an isolated development environment. It lives in the [rhdh-templates](https://github.com/openshift-dev-days/rhdh-templates) repo.

### What It Creates

```
1. Feature branch on user's parasol-insurance repo (GitLab)

2. GitOps repo: <username>/parasol-insurance-<branch>-gitops
   └── helm/          ← Namespaced resources only
       ├── deployment, service, route (app + DB)
       ├── pipeline (Clone → SonarQube → Build+Push → Re-rollout)
       ├── event listener + webhook job
       └── ExternalSecrets (GitLab, Quay, SonarQube, LiteLLM, Kafka)

3. Bootstrap repo: parasol/parasol-insurance-<username>-<branch>-bootstrap
   └── application.yaml  ← ArgoCD Application pointing at helm/ above

4. ArgoCD bootstrap Application (in default project)
   └── Creates child Application (in user's AppProject)
       └── Deploys helm/ chart into <username>-<branch> namespace

5. Catalog entry: parasol-insurance-dev-<username> Component
```

### Security Model

The template uses a two-repo pattern to prevent privilege escalation:

```
┌─────────────────────────────────────────────────────┐
│ Bootstrap repo (parasol group - user CANNOT write)  │
│                                                     │
│  application.yaml                                   │
│    project: appproject-<user>  ← restricted         │
│    source: user's gitops repo                       │
│    path: helm/                                      │
│                                                     │
│  Managed by: ArgoCD bootstrap app (default project) │
└──────────────────────┬──────────────────────────────┘
                       │ creates
                       ▼
┌─────────────────────────────────────────────────────┐
│ Child ArgoCD Application                            │
│   project: appproject-<user>                        │
│   destinations: <user>-* namespaces only            │
│   cluster resources: Namespace only                 │
│   source: user's gitops repo, path: helm/           │
└──────────────────────┬──────────────────────────────┘
                       │ deploys from
                       ▼
┌─────────────────────────────────────────────────────┐
│ GitOps repo (user's account - user CAN write)       │
│                                                     │
│  helm/                                              │
│    Only namespaced resources                        │
│    Constrained by AppProject                        │
│    Cannot create ClusterRoleBindings, etc.          │
└─────────────────────────────────────────────────────┘
```

The `ClusterRoleBinding` for Tekton `openshift-pipelines-clusterinterceptors` is granted **cluster-wide** to all ServiceAccounts (read-only on ClusterInterceptor metadata — not sensitive). This avoids needing per-environment cluster-scoped resources.

### Pipeline

The CI/CD pipeline has 4 stages matching the workshop scenario:

1. **Clone** — git-clone from the feature branch
2. **SonarQube SAST** — code quality analysis
3. **Build and Push** — Buildah container build, push to Quay
4. **Re-rollout** — restart deployment with new image

Triggered by GitLab webhooks via Tekton EventListener. The base tenant build pipeline filters to `main` branch only; dev environment pipelines filter to their specific feature branch.

## Key Learnings

Things that tripped us up during development:

- **RHDH operator** creates routes as `backstage-developer-hub-<namespace>.*`, not `developer-hub-<namespace>.*`
- **Keycloak route** is `sso.*`, not `keycloak-keycloak.*`
- **keycloakOrg plugin** defaults `loginRealm` to `master` — must set explicitly if the client is in another realm
- **Dynamic plugins**: overriding a plugin entry in `includes` replaces the entire entry including `pluginConfig`
- **`permission.enabled: true`** is required in app-config for RBAC to work
- **Vault setup job** can overwrite manually-seeded secrets on re-run — always wire secrets through the full app-of-apps chain
- **GitLab mirror push** carries branch protection from the source repo — unprotect before pushing
- **ArgoCD `argocd:create-resources`** action always tries to create an AppProject when `projectName` is set — use unique names or omit it
- **GitLab repo visibility** defaults to private for user namespaces — explicitly set to public after import since ArgoCD has no GitLab credentials
