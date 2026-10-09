# Module 2 dependency and image baseline

Tracking issue: [#51](https://github.com/rhpds/ocp-dev-days-rdshw-gitops/issues/51)

## Source of truth

Tenant bootstrap mirrors the `parasol` group's `parasol-insurance` and
`parasol-insurance-manifests` repositories into each participant's GitLab
namespace. See `tenant/bootstrap/templates/cm-tenant-setup.yaml`. The initial
build in `tenant/parasol-insurance-tenant/templates/job-initial-build.yaml`
starts the `parasol-insurance-push` PipelineRun from the imported manifests.
Changes to Maven dependencies, the application base image, or Tekton build
images therefore belong in the upstream source repositories before new
tenants are provisioned:

This inventory was read at `parasol-insurance` commit
`9f60adfbd10a00f090c637546573f50660a36631` and
`parasol-insurance-manifests` commit
`3a2f066cd389e614876bf4237988313ceb3b08d6`.

| Input | Upstream source | Observed on `main` (2026-10-10) |
| --- | --- | --- |
| Quarkus BOM and direct dependencies | [parasol-insurance `pom.xml`](https://github.com/openshift-dev-days/parasol-insurance/blob/main/pom.xml) | Quarkus BOM `3.17.5`; Java release `17` |
| Application base image | [parasol-insurance `Containerfile`](https://github.com/openshift-dev-days/parasol-insurance/blob/main/Containerfile) | `registry.access.redhat.com/ubi9/openjdk-21-runtime:1.20` |
| Maven and Sonar task images | [parasol-insurance-manifests `build/templates`](https://github.com/openshift-dev-days/parasol-insurance-manifests/tree/main/build/templates) | `registry.access.redhat.com/ubi9/openjdk-21:1.20` |
| Built application image | `parasol-insurance-push` pipeline in the same manifests repository | Built from `Containerfile`, pushed to the tenant's Quay organization with tag `latest` |

These values are an inventory, **not** an approved security baseline. The
pipeline's SonarQube task is a code-quality check; its success alone does not
establish the expected Trusted Profile Analyzer (TPA) findings.

## Baseline refresh

Run this before each workshop release and after a material upstream image or
dependency change. The release owner records the result in issue #51 or a
linked release issue.

1. Record the exact upstream commit IDs for both repositories and the
   workshop GitOps and guide commits. Import those commits into a fresh test
   tenant; existing tenant copies do not automatically receive upstream
   changes.
2. Run the unmodified `parasol-insurance-push` pipeline. Record the
   PipelineRun URL, completion time, task results, and built image digest.
   Resolve a failed build or scan before using the image as the baseline.
3. Run TPA against the built image and the resolved Maven dependency set.
   Capture the report URL or exported report, scan time, image digest, and
   vulnerability identifiers with severity and package version. Record the
   scanner database/update date so later comparisons are meaningful.
4. Classify each finding as expected for the lab, fixed by a tested upstream
   change, or an exception with a named owner and follow-up issue. Do not
   infer safety from a finding count alone.
5. Compare the recorded results with the participant guide. Update its
   screenshots and stated findings when they differ, then rerun the pipeline
   and TPA after any upstream change. Record the final upstream commits,
   image digest, report, and guide commit in the tracking issue.

The workshop release owner reviews this baseline monthly while the lab is
active, and again before each event. An upstream source maintainer owns
dependency and image updates; the workshop guide maintainer owns participant
instructions and screenshots. Any unexpected finding needs an explicit owner
and disposition before issue #51 is closed.
