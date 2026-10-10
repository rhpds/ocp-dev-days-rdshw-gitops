# Catalog isolation rollout for existing tenants

Tracking issue: [showroom #30](https://github.com/rhpds/ocp-dev-days-rdshw-showroom/issues/30)

This runbook coordinates the catalog changes in the [Parasol source PR](https://github.com/openshift-dev-days/parasol-insurance/pull/7), [RHDH template PR](https://github.com/openshift-dev-days/rhdh-templates/pull/3), and [GitOps PR](https://github.com/rhpds/ocp-dev-days-rdshw-gitops/pull/48). Keep the policy change last. The tenant bootstrap in `tenant/bootstrap/templates/cm-tenant-setup.yaml` mirrors and renders `catalog-info.yaml.template` only when it provisions a tenant. Merging the source PR does not update existing tenant GitLab copies.

## Observed starting state

On the 2026-10-10 test cluster, the Developer Hub catalog contained one `system:default/parasol-insurance`, owned by `group:default/users`. Its `hasPart` relations included both `user1` and `user2` Components and APIs, plus `resource:default/llm-inference-server`. The tenant entities came from each user's GitLab `parasol-insurance/main/catalog-info.yaml`; the shared System came from `parasol/parasol-catalog-entities/system.yaml`. The deployed RBAC policy still grants all developers read access to System and API entities by kind. This confirms the reported cross-tenant relation in the current deployment. It does not validate the proposed policy or a signed-in user's post-migration view.

## Prepare and record a rollback point

1. Confirm both test users can sign in to Developer Hub and that each GitLab `parasol-insurance` project has a working `main` branch. Record the source commit, each tenant's `main` commit, the shared catalog repository commit, the GitOps revision, and the current `rhdh/rbac-policy` ConfigMap revision. Use commit IDs in the tracking issue; do not copy credentials into the issue or this document.
2. Save a copy of the two existing tenant `catalog-info.yaml` files and the shared `parasol-catalog-entities` System definition in their repositories or a controlled backup. Record the current catalog entity and relation list. Preserve the existing tenant branches and application code.
3. Merge the Parasol source and RHDH template PRs first. Confirm the source template now renders a tenant-owned `System` named `parasol-insurance-<user>`, and both the API and Component reference that System. Confirm the scaffolded development Component also references `parasol-insurance-<user>`.
4. Decide where `resource:default/llm-inference-server` belongs after the shared System is retired. It currently has a `hasPart` relation from that System. Either give the resource a separate, deliberately shared System with an explicit owner and access policy, or remove the relation if the resource does not belong in a System. Record the decision before deleting the old System.

## Migrate the existing tenant copies

For `user1`, then `user2`, make a normal GitLab commit in that user's `parasol-insurance` project. In `main/catalog-info.yaml`:

- Change the Component and API `spec.system` values from `parasol-insurance` to `parasol-insurance-<user>`.
- Add a `System` document with `metadata.name: parasol-insurance-<user>` and `spec.owner: user:default/<user>`, as rendered from the merged upstream template.
- Keep the existing Component/API names and owners. Check that any local edits to the file are retained.

Wait for the GitLab catalog provider to ingest each commit. Its configured poll frequency is five minutes; allow for processing time beyond that. As an admin, confirm that each new System, Component, and API exists, that every `partOf` relation points to its matching tenant System, and that each new System's `hasPart` relations contain only that tenant's entities. Do not proceed while either tenant still points to the shared System. A fresh tenant provisioned after the source merge should render the same entity shape without manual edits.

## Retire the shared System, then tighten reads

1. Update the `parasol-catalog-entities` GitLab source so `system:default/parasol-insurance` is no longer registered. Preserve unrelated entities. Resolve the LLM resource relationship as decided above. Wait until Developer Hub no longer lists the shared System or any stale `partOf`/`hasPart` relations to it.
2. Merge and sync the GitOps policy change. Check the live `rhdh/rbac-policy` ConfigMap: the `IS_ENTITY_KIND` read list must exclude `system` and `api`, while `IS_ENTITY_OWNER` remains. Confirm the Developer Hub rollout has loaded the policy and the Argo CD `developer-hub` application is Synced and Healthy.
3. Sign in separately as `user1` and `user2`, preferably with separate browser profiles. For each user, open Catalog Systems, APIs, and Components. The user's own System, API, and Components must be visible and navigable. The other user's System and API must not appear in lists or direct entity URLs. Check the user's Component → System → API navigation and the scaffolded development Component after running its template. Repeat any direct API check with each user's normal session rather than an admin or service token.
4. Check that templates, groups, users, locations, domains, and resources needed by the lab remain visible. Compare the Module 1 instructions and screenshots with the resulting entity names. Attach the two-user results and exact deployed revisions to #30 before marking it fixed.

## Stop and rollback

If a tenant loses its own System/API or a dependent catalog workflow breaks, stop before moving to the next stage. Restore the last known-good GitOps RBAC revision first if the policy was synced, then restore the shared catalog source and any affected tenant `catalog-info.yaml` commits. Wait for ingestion and verify both tenant views again. Revert through normal Git/Argo reconciliation so the live state and source of truth agree; avoid a one-off ConfigMap edit. If only one tenant's catalog migration failed before the policy change, restore that tenant's file and leave the shared System and original RBAC in place while investigating.
