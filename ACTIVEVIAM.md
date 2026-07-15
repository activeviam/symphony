# ActiveViam Symphony pilot

This is the continuation guide for the ActiveViam fork. Read it before changing the fork,
the pilot workflow, or the Shared EKS deployment.

Last live verification: 2026-07-15.

## Starting point

- Upstream: [openai/symphony](https://github.com/openai/symphony)
- ActiveViam fork: [activeviam/symphony](https://github.com/activeviam/symphony)
- Upstream baseline: 4cbe3a9 ([web] Add Symphony favicon (#90))
- Fork head before this guide: 0db0004 (fix Jira Req options)
- Pilot repository: [activeviam/atoti-risk-admin-dashboard](https://github.com/activeviam/atoti-risk-admin-dashboard)
- Jira project: ATRS, board 1706
- Dispatch opt-in label: symphony

The fork started from an unchanged upstream checkout and intentionally adds Jira support,
container packaging, GitHub App authentication, and the ActiveViam review loop. To refresh the
comparison:

~~~bash
git fetch origin upstream
git log --oneline --reverse upstream/main..origin/main
git diff --stat upstream/main...origin/main
git diff --name-status upstream/main...origin/main
~~~

At the baseline above the fork is three commits and 27 files ahead of upstream: 2,487 insertions
and 69 deletions.

## Goal and safety boundary

The prototype turns explicitly labelled ATRS tickets into draft pull requests against one pilot
repository. It is deliberately conservative:

- Unlabelled Jira work is never dispatched.
- The implementation worker and independent AI reviewer are separate Symphony processes.
- Neither process merges a pull request, deploys an application, or moves a ticket to Done.
- AI findings and current human review findings return the ticket to In Progress.
- A clear AI review moves the ticket to Human Review.
- Image promotion changes Shared EKS only through a reviewed pull request in
  activeviam/shared-infrastructure.

The intended issue lifecycle is:

~~~mermaid
flowchart LR
  S["Selected for Development"] --> I["In Progress"]
  I --> A["AI Review"]
  A -->|findings| I
  A -->|clear| H["Human Review"]
  H -->|current PR findings| I
  H -->|human decision| M["Merge / Done outside Symphony"]
~~~

## Repository ownership

| Repository or system | Owns |
| --- | --- |
| activeviam/symphony | Symphony source, Jira adapter, claim leases, container image, review watcher, and CI |
| activeviam/shared-infrastructure | Argo CD application, worker/reviewer deployments, workflows, services, ingress, ExternalSecrets, CronJob, and image digest |
| Derivitec/derivitec-infrastructure | Shared EKS add-ons, Pod Identity association and IAM, and Jira OAuth refresh infrastructure |
| Derivitec/aws-cloud-formation | Symphony ECR repository and central AWS/EKS infrastructure |
| activeviam/atoti-risk-admin-dashboard | The only implementation target during the pilot |
| ActiveViam Jira ATRS | Human-shared queue, symphony label gate, AI Review, and Human Review states |

Keep changes in the repository that owns the resource. In particular, never patch the cluster
directly: change services/symphony in activeviam/shared-infrastructure and let Argo CD reconcile it.

## What differs from upstream

### Jira and tracker behaviour

- Jira Cloud REST v3 adapter with enhanced JQL pagination and ADF normalization.
- Required-label dispatch gating for a board shared with humans.
- Durable claim leases stored in Jira comments, including lease renewal and takeover protection.
- Project-scoped Jira comment and transition tools exposed to Codex.
- Retry and rate-limit handling for safe Jira reads.
- A mounted Jira OAuth token file that is reread on every request so token rotation does not
  require a pod restart.
- Tracker-neutral orchestrator extensions, while some inherited Linear-named types remain.

### Runtime and authentication

- A pinned, multi-architecture, non-root container image in elixir/Dockerfile.
- Codex CLI, Git, GitHub CLI, Jira helpers, and the review watcher in the runtime image.
- GitHub App installation tokens minted just in time for GitHub CLI and Git operations.
- Amazon Bedrock through the standard AWS credential chain and EKS Pod Identity; no OpenAI API key
  or personal GitHub token is placed in the pod.

### ActiveViam workflow policy

- Worker states: Selected for Development and In Progress.
- Reviewer state: AI Review.
- AI-clear transition: AI Review to Human Review.
- AI or human findings: return to In Progress.
- A two-minute CronJob checks current human PR findings while a ticket is in Human Review.

The deployed worker and reviewer prompts in
activeviam/shared-infrastructure/services/symphony/base are authoritative. The examples in this
repository mirror that split but do not deploy it.

### Small compatibility fix

The fork omits absent Req options instead of passing params: nil. This fixes a Jira startup crash
and has a focused regression test.

## Live prototype shape

As of the verification date:

- Shared EKS namespace symphony has one implementation worker, one AI reviewer, and the review
  watcher CronJob.
- Both deployments use the same immutable ECR digest and the same Symphony image.
- Bedrock model openai.gpt-5.6-sol is selected through EKS Pod Identity.
- Worker and reviewer have separate services and ingress target groups.
- Their dashboards currently look the same because they render the same UI. A visible role banner
  is still needed; identical appearance does not mean the routing is shared.
- Workspaces, logs, and home directories use emptyDir volumes. Jira claims survive restarts, but
  local workspace contents do not.

Internal dashboards:

- https://symphony.shared.internal.activeviam.com
- https://symphony-reviewer.shared.internal.activeviam.com

Useful read-only checks:

~~~bash
kubectl config current-context
kubectl -n symphony get deploy,pods,cronjob,jobs
kubectl -n symphony get svc,ingress
kubectl -n argocd get application symphony-credentials

aws sts get-caller-identity
aws ecr describe-images --region us-east-1 --repository-name symphony

gh pr list --repo activeviam/shared-infrastructure --state open
gh run list --repo activeviam/symphony --limit 20
~~~

Before any destructive Kubernetes command, explicitly verify the current context and make the
underlying manifest change through GitOps instead.

## CI and deployment

.github/workflows/make-all.yml is the upstream-compatible pull-request and main-branch test gate.

.github/workflows/publish-shared.yml runs only for this fork. It:

1. Accepts a successful make-all push run on main, or a manual retry launched from main.
2. Re-runs make all for a manual retry and rejects a source commit that is not in main.
3. Builds ARM64 on the shared-arm64-activeviam ARC runner.
4. Publishes an immutable ECR tag named git-<full-source-sha>-arm64 and resolves its digest.
5. Uses the ActiveViam Symphony Deployer GitHub App to update only
   services/symphony/envs/shared/kustomization.yaml.
6. Pushes a deployment branch and opens a pull request in activeviam/shared-infrastructure.
7. Stops. It never merges the deployment pull request.

The deployment job uses activeviam-shared-arm64-small. The App is installed only on
activeviam/shared-infrastructure with repository contents and pull-request read/write access.
The source repository holds:

- Actions variable SYMPHONY_DEPLOY_APP_ID
- Actions secret SYMPHONY_DEPLOY_APP_PRIVATE_KEY

This deployment App is intentionally separate from the runtime App mounted in EKS. Giving the
runtime App access to shared-infrastructure would allow an implementation workload to modify its
own deployment and is outside the prototype boundary.

After this workflow first reaches main, the expected chain is:

~~~text
merge source PR
  -> make-all succeeds on main
  -> publish-shared builds or reuses the immutable image
  -> deployment PR is opened
  -> human reviews and merges the deployment PR
  -> Argo CD reconciles Shared EKS
~~~

## Candidate upstream contributions

Contribute these as small, independent changes rather than proposing the complete ActiveViam
deployment policy upstream:

| Candidate | Recommendation |
| --- | --- |
| Omit absent Req options | Best first contribution: small bug fix with a regression test |
| Jira tracker adapter | Coordinate with upstream PR 83 and split transport from ActiveViam policy |
| Jira claim leases | Propose as tracker-neutral lease semantics after agreeing the contract |
| Required-label dispatch gate | Useful generic safety feature for any shared tracker |
| Token-file reread and retry handling | Generic operational hardening with little policy coupling |
| Tracker-neutral issue type names | Follow-up refactor after Jira behaviour is accepted |
| Container reference implementation | Offer separately; keep Bedrock, EKS, and ActiveViam defaults out |
| Dashboard instance/role label | Generic improvement for multiple Symphony instances |

Keep these ActiveViam-owned unless upstream asks for a general abstraction:

- ATRS status names and the symphony label.
- The atoti-risk-admin-dashboard pilot binding.
- AI Review/Human Review transition policy and review-comment wording.
- Bedrock model choice, AWS IAM, EKS manifests, internal ingress, and GitOps promotion.
- The human-review polling CronJob in its current repository-specific form.

## Known gaps before broader use

- Run one disposable ATRS issue through the complete implementation, AI review, rework, and human
  review loop; the infrastructure is live but this remains the most important proof.
- Add visible worker/reviewer identity and active-state information to the dashboard.
- Decide on persistent workspace recovery rather than emptyDir before relying on long-running work.
- Add NetworkPolicy, availability/disruption policy, alerting, and an explicit UI authentication
  decision.
- Review Inspector findings and base-image refresh policy before treating the image as production
  hardened.
- Define a regular upstream-sync cadence and keep upstreamable commits isolated.

## Recommended next task

After the CI/deployment PR for this guide is merged:

1. Watch make-all and publish-shared.
2. Review the generated shared-infrastructure pull request and confirm it changes one digest only.
3. Merge that deployment pull request manually if its checks and diff are acceptable.
4. Verify Argo CD sync, both deployments, the CronJob, and the two ingress routes.
5. Create a small disposable ATRS ticket labelled symphony and exercise the complete review loop.
6. Make the dashboard role/instance distinction the next source change.

A useful opening prompt for a new Codex task is:

> Read ACTIVEVIAM.md completely. Re-check origin/main, upstream/main, the current GitHub Actions
> runs, activeviam/shared-infrastructure, and the live read-only Shared EKS state. Continue from the
> recommended next task without merging a pull request or changing the cluster directly.
