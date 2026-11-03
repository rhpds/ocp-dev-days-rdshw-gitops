# OCP Dev Days Roadshow - GitOps

Helm charts and ArgoCD manifests for the OpenShift Developer Experience workshop.

## Architecture Overview

This workshop uses a multi-tenant model on a shared OpenShift cluster. Each participant (tenant) gets isolated resources provisioned on-demand, including a Parasol Insurance application, CI/CD pipelines, a secured software supply chain, and a Developer Hub catalog entry.

### Cluster-Level Components

Deployed once via the **app-of-apps** pattern (`cluster/app-of-apps/`):

| Component | Chart Path | Description |
|-----------|-----------|-------------|
| Catalog Sources | `cluster/catalog-sources/` | OLM catalog snapshot for operator version pinning |
| Vault | `cluster/vault/` | HashiCorp Vault for secrets management |
| External Secrets | `cluster/external-secrets/` | Syncs Vault secrets to Kubernetes Secrets |
| GitLab | `cluster/gitlab/` | Source code hosting (repos imported from GitHub) |
| Quay | `cluster/quay/` | Container image registry |
| OpenShift Pipelines | `cluster/openshift-pipelines/` | Tekton operator |
| Dev Spaces | `cluster/devspaces/` | Cloud development environments |
| OpenVSX | `cluster/openvsx/` | VS Code extension registry for Dev Spaces |
| Workspace Images | `cluster/workspace-images/` | Custom DevSpaces workspace images (gitsign, syft) |
| SonarQube | `cluster/sonarqube/` | Code quality analysis |
| AMQ Streams | `cluster/amq-streams/` | Kafka operator and broker |
| Developer Hub Prereqs | `cluster/developer-hub-prereqs/` | RHDH operator (v1.9) + SA token writer |
| Developer Hub | `cluster/developer-hub/` | Backstage CR, app-config, RBAC, plugins |
| Tenant Prereqs | `cluster/tenant-prereqs/` | Shared tenant RBAC, clusterinterceptors CRB |
| RHACS | `cluster/rhacs/` | Advanced Cluster Security (Central, SecuredCluster, SSO) |
| RHTAS | `cluster/rhtas/` | Trusted Artifact Signer (Fulcio, Rekor, TUF, CT Log) |
| TPA | `cluster/tpa/` | Trusted Profile Analyzer (SBOM analysis, RHDA backend) |
| Policy Controller | `cluster/policy-controller/` | Sigstore policy-controller operator |
| Parasol Policy Controller | `cluster/parasol-policy-controller/` | ClusterImagePolicies + TrustRoot setup |
| Parasol Approval | `cluster/parasol-approval/` | Release approval web app for signed attestations |

### Module 3 Components

Deployed via a nested app-of-apps (`cluster/module3/app-of-apps/`):

| Component | Chart Path | Description |
|-----------|-----------|-------------|
| Connectivity Link | `cluster/module3/connectivity-link/` | Kuadrant operator + AI Gateway |
| Service Interconnect | `cluster/module3/service-interconnect/` | Skupper operator |
| Shared Database | `cluster/module3/shared-database/` | Shared PostgreSQL for multi-site |
| Camel Flows | `cluster/module3/camel-flows/` | Camel K integration flows |
| RocketChat | `cluster/module3/rocketchat/` | Team messaging |
| Matrix | `cluster/module3/matrix/` | Matrix messaging server |
| Helpdesk | `cluster/module3/helpdesk/` | Helpdesk application |
| Filestash | `cluster/module3/filestash/` | File management UI |
| Showroom | `cluster/module3/showroom/` | Workshop lab guide |
| Admin | `cluster/module3/admin/` | Admin namespace with Vault/S3 seed jobs |

### Tenant Provisioning

Each tenant is provisioned by the RHDP platform running Ansible workloads defined in [agnosticv](https://github.com/rhpds/agnosticv). The flow:

1. **Keycloak user** created in the `sso` realm, added to the `users` group
2. **ArgoCD AppProject** created (`appproject-<username>`) restricting deployments to `<username>-*` namespaces
3. **GitOps bootstrap** Application created, which deploys the tenant chart (`tenant/bootstrap/`)

The tenant bootstrap chart (`tenant/bootstrap/`) runs a Job that:

- Creates the user in GitLab and Quay
- **Imports** (not forks) `parasol-insurance`, `parasol-insurance-manifests`, `parasol-insurance-secured`, and `parasol-insurance-secured-manifests` repos from the `parasol` group into the user's GitLab namespace
- Sets repos to **public** visibility (ArgoCD has no GitLab credentials)
- Unprotects the `main` branch (mirror push carries protection)
- Templates `catalog-info.yaml` with the user's GUID and cluster subdomain
- Commits and pushes the templated catalog-info

### Tenant Charts

| Chart | Path | Description |
|-------|------|-------------|
| Bootstrap | `tenant/bootstrap/` | User provisioning job, shared Dev Spaces namespace/RBAC, child app creation |
| Parasol Insurance | `tenant/parasol-insurance-tenant/` | Base app: build/dev/prod namespaces, pipelines, ArgoCD apps |
| Parasol Insurance Secured | `tenant/parasol-insurance-secured-tenant/` | Secured app: build/preprod/prod namespaces, secured pipelines, ArgoCD apps |
| Module 3 Workload | `tenant/module3/` | Per-tenant Kafka, Camel, DevWorkspace, DB, messaging |
| Module 5 Workload | `tenant/module5/` | Per-tenant MTA migration namespace and DevWorkspace |

Bootstrap owns `<username>-devspaces` and its `<username>-edit` RoleBinding
whenever module 3 or module 5 is enabled. They sync at wave `-1`, before the
module Applications at wave `3`. The module charts depend on bootstrap for
these shared prerequisites and never declare them themselves. Dev Spaces
namespace auto-provisioning remains enabled; the workshop pre-creates the
namespace to provision workspaces before user login. Module 5 still owns its
separate `<username>-ai-mta` namespace and RoleBinding.

Existing tenants require a staged ownership transfer before upgrading.
Do not disable both modules as an ownership-migration shortcut: removing a
namespace from desired state can prune it even when it has `Delete=false`.

## Secured Software Supply Chain

The secured pipeline adds signing, attestation, and policy enforcement on top of the base CI/CD pipeline.

### Components

- **Trusted Artifact Signer (RHTAS)** -- provides Fulcio (certificate authority), Rekor (transparency log), and cosign/gitsign binaries for keyless signing
- **Tekton Chains** -- automatically signs pipeline runs and attests build provenance (SLSA v0.2)
- **Gitsign** -- signs git commits in DevSpaces using the developer's Keycloak identity
- **Enterprise Contract (EC)** -- validates images against Conforma/Rego policies before promotion
- **Policy Controller** -- enforces ClusterImagePolicies on deployments (signature verification, signed commits, release approval)
- **Parasol Approval** -- web application for human release approval with signed attestations
- **ACS (RHACS)** -- image vulnerability scanning and policy enforcement
- **TPA** -- SBOM generation, upload, and dependency analysis

### Secured Pipeline Flow

```
Developer commit (gitsign-signed)
  → GitLab webhook
  → MR Check pipeline (sandbox build, SonarQube, ACS scan)
  → Merge to main
  → Push pipeline:
      Clone → Maven Build → SonarQube → ACS Image Check → ACS Image Scan
      → Buildah Build+Push → Verify Commit Signature → Generate SBOM
      → Tekton Chains signs + attests
  → Tag + Promote pipeline:
      Get Image SHA → EC Validate (Conforma policies) → Skopeo Copy to prod
      → Update prod manifest → Report status to GitLab
  → Release Approval (human signs attestation via Parasol Approval app)
  → Policy Controller enforces on deployment
```

### Conforma Policies

Custom Rego policies in the [conforma-policies](https://github.com/openshift-dev-days/conforma-policies) repo, evaluated by EC during the tag-promote pipeline:

| Policy | Type | What it checks |
|--------|------|----------------|
| acs_image_check | deny | ACS image policy check task ran and passed |
| acs_image_scan | deny/warn | ACS scan task ran; warns on vulnerabilities |
| commit_signature | deny | Commit is signed by a human (not bot) |
| release_approval | deny | Signed release approval attestation present |
| sonarqube | deny/warn | SonarQube quality gate passed; warns on findings |

### ClusterImagePolicies

Enforced by the sigstore policy-controller on image deployments:

| Policy | Enforcement |
|--------|-------------|
| parasol-image-signature-required | Image must be signed by Tekton Chains or Red Hat |
| parasol-signed-commit-required | SLSA provenance must show a signed commit |
| parasol-release-approval-required | Release approval attestation must be approved |

## Operator Version Pinning

Operators are pinned via two mechanisms:

- **Catalog snapshot** (`redhat-operators-snapshot`) -- a frozen OLM catalog image for operators that should not auto-upgrade (AMQ Streams, Quay, DevSpaces, Kuadrant, Skupper)
- **Live catalog with versioned channels** -- for operators needing the latest patches (RHACS on `rhacs-4.11`, RHTAS on `stable-v1.4`, Policy Controller on `stable-v1.1`)

## Developer Hub (RHDH)

### Catalog Entity Model

```
Shared (visible to all users):
  System: parasol-insurance, parasol-insurance-secured
  API: parasol-insurance-api, parasol-insurance-secured-api
  Resources: kafka-cluster, llm-inference-server
  Templates: Parasol Insurance Development Environment,
             Secured Parasol Insurance Development Environment
  Groups: users, admins
  Users: (synced from Keycloak)

Per-user (visible only to owner via RBAC):
  Component: parasol-insurance-<username>
  Component: parasol-insurance-secured-<username>
    - From catalog-info.yaml in user's GitLab repos
    - Annotations link to ArgoCD apps, K8s namespaces, pipelines
```

### RBAC Model

| Role | Permissions | Assigned To |
|------|------------|-------------|
| `role:default/admin` | Full catalog CRUD (unrestricted) | `group:default/admins` |
| `role:default/developer` | Catalog read (conditional) | `group:default/users` |
| `role:default/scaffolder_execute` | Template execution | `group:default/users`, `group:default/admins` |
| `role:default/plugins` | Kubernetes, Tekton, ArgoCD, Lightspeed | `group:default/users`, `group:default/admins` |

The `developer` role has **conditional read policies**:

- **Components**: users can only see entities they own (`IS_ENTITY_OWNER`)
- **Shared types** (System, API, Template, Group, User, Location, Domain, Resource): visible to all
- **Update/Delete**: only on owned entities

## Software Templates

### Parasol Insurance Development Environment

Creates an isolated dev environment with a basic CI/CD pipeline (clone, SonarQube, build, deploy).

### Secured Parasol Insurance Development Environment

Creates a secured dev environment with the full supply chain: gitsign-signed commits, ACS scanning, commit signature verification, and EC policy validation on promotion.

Both templates live in the [rhdh-templates](https://github.com/openshift-dev-days/rhdh-templates) repo and use the two-repo bootstrap pattern for ArgoCD security isolation:

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
> Labels must be on resource **metadata** (not just pod templates). The Kubernetes plugin fetches Deployments, Services, Routes etc. by label -- if only pod templates have the label, only pods show up in the UI.

## Key Learnings

Things that tripped us up during development:

- **RHDH operator** creates routes as `backstage-developer-hub-<namespace>.*`, not `developer-hub-<namespace>.*`
- **Keycloak route** is `sso.*`, not `keycloak-keycloak.*`
- **keycloakOrg plugin** defaults `loginRealm` to `master` -- must set explicitly if the client is in another realm
- **Dynamic plugins**: overriding a plugin entry in `includes` replaces the entire entry including `pluginConfig`
- **`permission.enabled: true`** is required in app-config for RBAC to work
- **Vault setup job** can overwrite manually-seeded secrets on re-run -- always wire secrets through the full app-of-apps chain
- **GitLab `import_url` API** is async and can take hours -- use synchronous `git clone --bare` + `git push --mirror` for repos that need post-import modifications (e.g. placeholder substitution)
- **GitLab mirror push** carries branch protection from the source repo -- unprotect before pushing
- **GitLab repo visibility** defaults to private for user namespaces -- explicitly set to public after import since ArgoCD has no GitLab credentials
- **EC (Enterprise Contract) v0.9.x** requires rego files under `policy/release/` directory with bare package names -- the `policy.release` namespace comes from directory structure, not the package declaration
- **EC caching bug** in v0.9.x: identical `--policy` and `sources[].policy[]` URLs trigger a broken symlink -- use slightly different URLs (e.g. omit `.git` suffix in sources)
- **Policy controller operator** is not in the Feb 2026 catalog snapshot -- must use the live `redhat-operators` catalog
- **Cosign v3.x** (TAS 1.4.x) adds `--use-signing-config` and `--new-bundle-format` flags not present in v2.x -- pods fetching cosign from the TAS cli-server at startup need a restart after TAS upgrades
