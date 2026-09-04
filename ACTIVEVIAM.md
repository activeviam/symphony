# ActiveViam Symphony continuation guide

This is the durable handoff for the ActiveViam fork, its Jira workflow, and the Shared EKS pilot.
Read it completely before changing Symphony or any connected infrastructure repository.

The source, GitOps manifests, and GitHub history were rechecked on 2026-09-04. The last live EKS
verification recorded in this project was 2026-07-23; treat every runtime statement below as a
verified historical baseline and recheck the live environment before acting.

## Starting point and repository state

- Upstream: [openai/symphony](https://github.com/openai/symphony)
- ActiveViam fork: [activeviam/symphony](https://github.com/activeviam/symphony)
- Original fork point: `4cbe3a9` (`[web] Add Symphony favicon (#90)`)
- Source image at the last verified deployment: `cf83efb` (`Prevent Jira polling from blocking
  health checks`, PR 13)
- Upstream head at the 2026-09-04 recheck: `8001b52`; upstream has advanced since the fork point,
  so the next source task must assess divergence before syncing
- Jira: ATRS project, board 1706
- Dispatch labels: `symphony` plus exactly one `symphony-repo-<repository>` label
- Original pilot target: [activeviam/atoti-risk-admin-dashboard](https://github.com/activeviam/atoti-risk-admin-dashboard)

The fork began as an upstream checkout and intentionally added Jira, secure container packaging,
GitHub App authentication, Bedrock/EKS runtime support, multi-repository routing, and the
ActiveViam review loop. Refresh the comparison rather than relying on the SHAs above:

~~~bash
git fetch origin upstream
git log --oneline --left-right upstream/main...origin/main
git diff --stat upstream/main...origin/main
git diff --name-status upstream/main...origin/main
~~~

Do not merge upstream mechanically. Separate generally useful changes from ActiveViam policy, and
retest the complete Jira workflow after resolving upstream changes.

## Goal and safety boundary

One state-aware Symphony deployment turns explicitly labelled ATRS tickets into reviewed draft
pull requests across GitHub App-accessible repositories in the `activeviam` organization. It is
deliberately conservative:

- Unlabelled Jira work is never dispatched, and repository routing fails closed.
- One Jira issue is scoped to one repository selected by an exact repository label.
- A single scheduler handles implementation and independent AI review, but every state boundary
  starts a fresh Codex session with a state-specific prompt.
- Symphony never merges a pull request, deploys an application, or moves a ticket to Done.
- AI findings and current human review findings return the ticket to In Progress.
- Missing access, external dependencies, or human decisions move the ticket to Blocked with one
  actionable Jira comment.
- A clear AI review marks the GitHub pull request ready and moves the ticket to Human Review.
- Image promotion changes Shared EKS only through a reviewed pull request in
  `activeviam/shared-infrastructure`; never patch the cluster directly.

The intended issue lifecycle is:

~~~mermaid
flowchart LR
  S["Selected for Development"] --> I["In Progress"]
  I --> A["AI Review"]
  I -->|human input required| B["Blocked"]
  A -->|findings| I
  A -->|cannot review| B
  A -->|clear; PR becomes ready| H["Human Review"]
  H -->|current PR findings| I
  B -->|human comments; reselect| S
  H -->|human merge and completion| D["Done outside Symphony"]
~~~

## Repository and system ownership

| Repository or system | Owns |
| --- | --- |
| `activeviam/symphony` | Fork source, Jira adapter, claim leases, container, routing/watcher scripts, examples, CI, and this guide |
| `activeviam/shared-infrastructure` | Authoritative deployed workflow, Argo CD application, deployment, service, ingress, ExternalSecrets, Human Review CronJob, and pinned image digest |
| `activeviam/atoti-risk-infrastructure-eks` | Shared EKS Pod Identity agent add-on, Symphony Bedrock IAM/association, Jira OAuth refresh Lambda, application team, and namespace |
| `activeviam/atoti-risk-infrastructure-network` | Centrally managed Symphony ECR repository (historically referenced through the Derivitec/AWS CloudFormation repository name) |
| ActiveViam GitHub App | Runtime repository access, Dependabot-alert visibility, and short-lived installation tokens |
| ActiveViam Jira ATRS | Human-shared queue, dispatch/routing labels, Blocked, AI Review, Human Review, and human guidance |
| Target repositories | Repository-specific instructions, tests, branch protection, pull requests, and application rollout |

Keep changes in the repository that owns the resource. The workflow under
`activeviam/shared-infrastructure/services/symphony/base/workflow.md` is authoritative for the
deployment; the examples in this repository are documentation and development fixtures.

## What differs from upstream

### Jira and tracker behaviour

- Jira Cloud REST v3 adapter with enhanced JQL pagination and ADF normalization.
- Required-label dispatch gating for a board shared with humans.
- Durable claim leases stored in Jira comments, including renewal and takeover protection. The
  deployed singleton uses one stable holder and retains leases for compatibility and future
  multi-scheduler safety; it does not require a second deployment.
- Project-scoped Jira comment and transition tools exposed to Codex.
- Jira comments included in resumed prompts with author and timestamp; internal lease markers are
  filtered so human guidance is visible without coordination noise.
- Retry and rate-limit handling for safe Jira reads.
- A mounted Jira OAuth access-token file reread for every request so AWS rotation does not require
  a pod restart.
- Tracker-neutral orchestrator extensions, while some inherited Linear-named types remain.

### Multi-repository routing

- `symphony-repo-<repository>` selects exactly one repository beneath the fixed `activeviam`
  organization.
- The router rejects missing, duplicate, malformed, inaccessible, or changed repository labels.
- GitHub App installation scope is the access boundary; Jira cannot supply another owner or an
  arbitrary clone URL.
- The Human Review watcher uses the same routing contract instead of scanning a hard-coded repo.
- One Jira issue remains one repository. Cross-repository planning/subtasks are future work.

### Runtime and authentication

- A pinned, non-root, ARM64-compatible container image in `elixir/Dockerfile` includes Codex CLI,
  Git, GitHub CLI, Jira helpers, the repository router, and the review watcher.
- GitHub App installation tokens are minted just in time for GitHub CLI and Git operations; the
  temporary personal token was removed.
- Codex uses Amazon Bedrock model `openai.gpt-5.6-sol` in `us-east-1` through the standard AWS
  credential chain and the managed EKS Pod Identity agent add-on. No OpenAI API key or static AWS
  credential is projected into the pod.
- A separate scheduled Lambda is the only writer of the rotating Jira OAuth grant. Kubernetes
  receives only the short-lived access token through External Secrets.

### ActiveViam workflow policy

- Active states: Selected for Development, In Progress, and AI Review.
- Inactive handoff states: Blocked, Human Review, Done, Cancelled/Canceled, and Duplicate.
- Capacity: five total concurrent runs, with AI Review capped at two.
- `agent.max_turns: 1` makes each state boundary a fresh session and prompt role.
- A clear AI review marks the draft PR ready before transitioning to Human Review.
- A two-minute CronJob detects current changes-requested reviews, unresolved non-outdated threads,
  and new collaborator comments on Human Review PRs and returns affected tickets to In Progress.

### Operational hardening and compatibility

- Missing Req options are omitted instead of passed as `nil`, fixing the initial Jira polling
  crash.
- `GET /healthz` returns process-only health without waiting for Jira or orchestrator state.
  Kubernetes probes and the ALB use it; `/api/v1/state` remains the richer operational snapshot.
- GitHub Actions dependencies are pinned and updated to Node 24-compatible releases.

## Last verified Shared EKS baseline

The following was verified on 2026-07-23 after the source and GitOps changes were merged:

- Namespace `symphony` had one non-root ARM64 deployment and the Human Review watcher CronJob.
- The deployment ran ECR digest
  `sha256:9f30daea486e105c8a10cc7c60887fe96525f2d197fbcd6e300b2dda88d079d5`.
- The deployment supported five concurrent tickets, with at most two AI reviews.
- The internal dashboard was available at
  `https://symphony.shared.internal.activeviam.com`; the earlier separate reviewer dashboard was
  removed when the two workers were consolidated.
- Kubernetes startup, readiness, and liveness probes and the ALB target group all used `/healthz`.
- Fifteen sustained checks returned HTTP 200: direct pod latency stayed below 1 ms and internal
  ALB latency was approximately 7–25 ms while normal Jira polling continued.
- Workspaces, logs, and home directories used `emptyDir`. Jira claims and PRs survive a restart;
  pod-local workspaces and full conversation history do not.
- The dashboard was an operational status UI, not a complete interactive Codex transcript viewer.

Recheck rather than assume that baseline still holds:

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

Before any destructive Kubernetes command, explicitly verify the current context. Make manifest
changes through `activeviam/shared-infrastructure` and allow Argo CD to reconcile them.

## CI and deployment

.github/workflows/make-all.yml is the upstream-compatible pull-request and main-branch test gate.

.github/workflows/publish-shared.yml runs only for this fork. It:

1. Accepts a successful make-all push run on main, or a manual retry launched from main.
2. Re-runs make all for a manual retry and rejects a source commit that is not in main.
3. Uses the ActiveViam Symphony Deployer GitHub App to send the tested source SHA to
   activeviam/shared-infrastructure as a repository-dispatch event.
4. Stops without running privileged work in this public repository.

The private activeviam/shared-infrastructure workflow then:

1. Verifies the requested commit belongs to activeviam/symphony main.
2. Builds ARM64 on the shared-arm64-activeviam ARC runner.
3. Publishes an immutable ECR tag named git-<full-source-sha>-arm64 and resolves its digest.
4. Updates only services/symphony/envs/shared/kustomization.yaml.
5. Pushes a deployment branch and opens a pull request.
6. Stops. It never merges the deployment pull request.

Privileged self-hosted runners are intentionally available only to private repositories. A public
repository can receive pull requests from forks, so enabling its workflows on AWS-enabled runners
would expand the trust boundary unnecessarily. The App is installed only on
activeviam/shared-infrastructure with repository contents and pull-request read/write access. The
source repository holds:

- Actions variable SYMPHONY_DEPLOY_CLIENT_ID
- Actions secret SYMPHONY_DEPLOY_APP_PRIVATE_KEY

This deployment App is intentionally separate from the runtime App mounted in EKS. Giving the
runtime App access to shared-infrastructure would allow an implementation workload to modify its
own deployment and is outside the prototype boundary.

After this workflow first reaches main, the expected chain is:

~~~text
merge source PR
  -> make-all succeeds on main
  -> publish-shared dispatches the tested SHA to the private repository
  -> shared-infrastructure builds or reuses the immutable image
  -> deployment PR is opened
  -> human reviews and merges the deployment PR
  -> Argo CD reconciles Shared EKS
~~~

## Future goal: deployed acceptance lane

The current prototype deliberately keeps a human-reviewed deployment pull request between image
publication and the human-used Shared EKS environment. Keep that behaviour until a separate,
isolated acceptance environment is available.

The future target flow is:

~~~text
merge source PR
  -> make-all succeeds on main
  -> private publisher builds or reuses the immutable image
  -> publisher directly updates an acceptance-only GitOps overlay or branch
  -> Argo CD reconciles an isolated Symphony acceptance namespace
  -> an environment-local private ARC runner waits for Synced and Healthy
  -> deployed acceptance tests run against the acceptance URLs
  -> success opens a human-reviewed PR promoting the same digest to Shared EKS
~~~

This makes deployed acceptance automatic after a trusted main-branch push without exposing the
stable shared instance to every source change. It also preserves Git as the source of truth; the
workflow must not patch Kubernetes resources directly.

The acceptance suite should verify:

- The dashboard is reachable and identifies whether each active run is implementing or reviewing.
- The running workload uses the exact ECR digest selected by the publisher.
- A disposable ATRS issue labelled symphony completes implementation, AI Review, and Human Review.
- AI or human findings return the issue to In Progress and the worker resumes it.
- Test issues and any temporary resources are reliably cleaned up or cancelled.

The existing `make e2e` target exercises upstream Linear/Codex behaviour and is not a substitute
for this Jira, Bedrock, EKS, ingress, and review-loop acceptance suite.

Guardrails for the future implementation:

- Accept only tested commits on activeviam/symphony main; do not deploy arbitrary public forks.
- Serialize acceptance deployments so concurrent pushes cannot overwrite each other's test target.
- Run environment-bound acceptance jobs on a private runner with Shared EKS network reachability.
- Prevent promotion when acceptance fails and retain enough Git history to identify or revert the
  failed acceptance deployment.
- Keep promotion to the human-used Shared EKS environment behind the deployment pull request.

This is a documented future goal only and does not change the current deployment workflow.

## Near-term multi-repository routing decision

Keep one Jira-driven Symphony scheduler and use labels for repository routing. Repository access
is organization-scoped rather than maintained as a second static allowlist.

- Keep `symphony` as the explicit dispatch opt-in label.
- Require exactly one repository label using the exact repository name in the form
  `symphony-repo-<repository>`, for example `symphony-repo-atoti-risk-admin-dashboard`.
- Always prepend the deployment-owned `activeviam` organization. Never accept an owner, arbitrary
  clone URL, or repository URL from Jira content.
- Install the runtime GitHub App for all repositories in the ActiveViam organization. The App
  installation is the effective access boundary, including for repositories created later.
- Keep one Jira issue scoped to one repository. Represent cross-repository work as linked issues
  or subtasks rather than allowing one coding run to create unrelated pull requests.
- Continue using repository-local instructions and CI as the authority for validation.

The repository router and human-review watcher consume the same label contract. Unknown,
inaccessible, missing, duplicated, or changed repository labels block safely instead of guessing
a target. The workspace router adds a deduplicated Jira comment when it cannot resolve a target.

This label-based contract is intentionally a prototype choice. A controlled Jira single-select
field may replace it later without allowing ticket authors to provide arbitrary repository URLs.

## Future goal: agent-planned cross-repository delivery

A later phase may add a planning and coordination agent that determines which allowlisted
repositories a parent Jira card affects, proposes a dependency-ordered plan, and creates one
repository-routed subtask per implementation unit.

The target flow is:

~~~text
parent Jira card enters planning
  -> planning agent reads the approved repository catalogue
  -> human approves the proposed repositories and dependency plan
  -> agent creates and links one subtask per repository
  -> each subtask follows implementation, AI Review, and Human Review independently
  -> coordinator collects immutable pull-request commit SHAs
  -> cross-repository acceptance runs in an isolated integration environment
  -> success creates a human-reviewed deployment PR in shared-infrastructure
  -> Argo CD deploys the approved revisions
  -> post-deployment acceptance completes the parent card
~~~

Design guardrails for that future work:

- Repository selection remains limited to repositories in the configured organization that the
  GitHub App installation can access.
- Require human plan approval initially; automation may be relaxed only for proven low-risk work.
- Add narrowly scoped Jira tools for creating subtasks, linking dependencies, and updating
  approved fields rather than exposing unrestricted Jira credentials to the coding agent.
- Use Jira states and dependency links as durable coordination state. Do not keep a manager agent
  running while it waits for child work.
- Test combined changes by immutable commit SHA, not mutable branch names.
- Route implementation, AI-review, human-review, integration, or acceptance findings back to the
  relevant repository subtask.
- Create deployment changes through a pull request against `activeviam/shared-infrastructure`;
  never patch Kubernetes resources directly.
- Keep rollout promotion and production-impacting decisions behind explicit human approval.

This is documented future work only. The next multi-repository implementation should use the
repository-label routing contract above and should not create subtasks or coordinate deployments
automatically.

## Future goal: secure agent conversation viewer

The current Symphony dashboard is an operational status surface. It shows active issues, session
identifiers, turn counts, token use, retry state, and the latest summarized Codex activity, but it
does not expose the complete visible agent conversation. The issue-detail API reserves a
`codex_session_logs` collection, which is currently empty.

A future dashboard enhancement should provide a read-only, issue-scoped conversation view without
exposing the live Codex app-server transport from EKS.

The target experience is:

~~~text
operator opens a Jira issue from the Symphony dashboard
  -> issue page lists implementation and AI-review sessions in chronological order
  -> each session shows visible prompts, agent messages, commands, tool calls, and results
  -> Jira transitions, pull-request revisions, and validation evidence are correlated on a timeline
  -> retained transcripts remain available after the worker pod or workspace is replaced
~~~

Implementation guidelines:

- Capture normalized visible app-server events in `AgentRunner` rather than parsing an unstable
  on-disk transcript format.
- Key records by Jira issue, Codex thread and turn, workflow role, repository, and immutable pull-
  request commit when available.
- Persist transcripts outside pod-local `emptyDir` storage with explicit retention and deletion
  policies.
- Extend `/api/v1/<issue_identifier>` and add a linked LiveView issue page for transcript browsing.
- Stream updates to the page while a session is active, but keep the first version read-only.
- Show user-visible prompts, agent messages, command and tool activity, concise command output, and
  validation results. Never expose hidden model reasoning.
- Redact credentials and sensitive environment values before persistence, and cap or separately
  store large command output.
- Protect transcript routes with the approved internal authentication and authorization mechanism;
  source code, diffs, commands, and Jira content must not become anonymously accessible.
- Record access and retain enough correlation data for operational and compliance investigation.
- Do not expose a pod's app-server WebSocket or stdio transport through the shared ingress. Any
  later steering or approval UI requires a separate threat model and explicit authorization.

This is documented future work only. The current dashboard and JSON API remain operational status
surfaces and do not provide a second interactive Codex UI.

## Delivery history and evidence

The following merged pull requests are the shortest reliable map from the original fork to the
last verified deployment. Read their diffs when changing the corresponding subsystem.

| Area | Pull requests | Result |
| --- | --- | --- |
| Jira foundation | `activeviam/symphony` [#1](https://github.com/activeviam/symphony/pull/1), [#3](https://github.com/activeviam/symphony/pull/3) | Jira adapter, mounted rotating token, dispatch labels, retry handling, and Req compatibility fix |
| Runtime security | `activeviam/symphony` [#2](https://github.com/activeviam/symphony/pull/2) | Non-root container, just-in-time GitHub App tokens, and Human Review watcher |
| Source CI and publishing | `activeviam/symphony` [#4](https://github.com/activeviam/symphony/pull/4) through [#8](https://github.com/activeviam/symphony/pull/8) | Tested-main dispatch to a private publisher, immutable ECR images, Node 24 actions, and separate deployment App credentials |
| Repository routing | `activeviam/symphony` [#11](https://github.com/activeviam/symphony/pull/11), `activeviam/shared-infrastructure` [#19](https://github.com/activeviam/shared-infrastructure/pull/19) | Organization-wide, fail-closed, one-repository-per-ticket routing |
| Human-blocked resumption | `activeviam/symphony` [#12](https://github.com/activeviam/symphony/pull/12), `activeviam/shared-infrastructure` [#22](https://github.com/activeviam/shared-infrastructure/pull/22) | Blocked status, actionable comments, and fresh runs that consume new human Jira guidance |
| Stateful review flow | `activeviam/shared-infrastructure` [#15](https://github.com/activeviam/shared-infrastructure/pull/15), [#16](https://github.com/activeviam/shared-infrastructure/pull/16) | One state-aware scheduler; clear AI review marks the PR ready before Human Review |
| Capacity | `activeviam/shared-infrastructure` [#24](https://github.com/activeviam/shared-infrastructure/pull/24) | Five concurrent runs with two AI Review slots |
| Independent health | `activeviam/symphony` [#13](https://github.com/activeviam/symphony/pull/13), `activeviam/shared-infrastructure` [#25](https://github.com/activeviam/shared-infrastructure/pull/25) and [#26](https://github.com/activeviam/shared-infrastructure/pull/26) | Constant `/healthz`, immutable image `cf83efb`, and probe/ALB migration |
| ECR | `activeviam/atoti-risk-infrastructure-network` [#1256](https://github.com/activeviam/atoti-risk-infrastructure-network/pull/1256) | Centrally managed Symphony ECR repository |
| Jira OAuth | `activeviam/atoti-risk-infrastructure-eks` [#254](https://github.com/activeviam/atoti-risk-infrastructure-eks/pull/254) | Single-writer scheduled refresh Lambda and Shared EKS namespace/team setup |
| Bedrock identity | `activeviam/atoti-risk-infrastructure-eks` [#255](https://github.com/activeviam/atoti-risk-infrastructure-eks/pull/255) | Managed Pod Identity agent, service-account association, and least-privilege `openai.gpt-5.6-sol` access |

ATRS-648 was the issue that demonstrated why an explicit Blocked state and resumed Jira comment
context were required. Later security-advisory tickets across `atoti-risk-*` repositories were
used to exercise repository routing and concurrency. Their current Jira/PR state is intentionally
not duplicated here; query Jira and GitHub before drawing conclusions from those experiments.

At the 2026-09-04 recheck, stale unmerged automated deployment PRs 17, 18, and 20 still existed in
`activeviam/shared-infrastructure`. They predate the deployed `cf83efb` digest and should be closed
after confirming they contain no unique desired change; do not merge them as an upgrade path.

## Related local experiment, not part of Symphony

After the EKS pilot, standalone personal `drive-jira-card` skills were prototyped for Codex and
Claude Code. They are intentionally unrelated to Symphony: a human explicitly names one Jira card,
the local coordinator triages and plans it, delegates bounded work to cheaper models, and asks for
human help only when required. They do not poll the board or use Symphony labels or leases.

The prototypes were created in the user-level Codex and Claude skill directories, not in this
repository, and were structurally validated but not exercised against a live Jira card. The Claude
version also requires completing the Atlassian OAuth MCP login. If that work resumes, pilot it in
several repositories first, then move portable copies to a dedicated shared skills repository;
do not fold it into this fork merely because the lifecycle is similar.

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
| Issue context for workspace hooks | Generic input for safe repository bootstrap without Jira-specific hook logic |
| Read-only session transcript projection | Generic dashboard/API enhancement using visible app-server events |
| Container reference implementation | Offer separately; keep Bedrock, EKS, and ActiveViam defaults out |
| Dashboard active-state/role label | Generic improvement for state-aware workflows |

Keep these ActiveViam-owned unless upstream asks for a general abstraction:

- ATRS status names and the symphony label.
- ActiveViam repository-label policy, organization boundary, and Jira routing-failure comments.
- AI Review/Human Review transition policy and review-comment wording.
- The ATRS `Blocked` state, its human-resumption policy, and Jira board column placement.
- Bedrock model choice, AWS IAM, EKS manifests, internal ingress, and GitOps promotion.
- The Jira-policy-specific human-review polling CronJob.

## Known gaps before broader use

- Recheck the live Shared EKS deployment; the last recorded runtime verification is from
  2026-07-23.
- Run one clean disposable ATRS issue through repository routing, implementation, AI-review
  findings, rework, clear AI review, ready-for-human-review, human feedback, merge, rollout, and
  cleanup. Earlier tickets exercised parts of this flow, not one durable end-to-end acceptance
  record.
- Add visible implementation/reviewer role and active-state information to the single dashboard.
- Decide on persistent workspace recovery rather than emptyDir before relying on long-running work.
- Add NetworkPolicy, availability/disruption policy, alerting, and an explicit UI authentication
  decision.
- Review Inspector findings and base-image refresh policy before treating the image as production
  hardened.
- Close obsolete automated deployment PRs after verifying they are superseded.
- Assess the now-significant upstream divergence, define a regular sync cadence, and keep
  upstreamable commits isolated.

## Recommended next task

Start with a read-only audit because the repository has been idle since July:

1. Fetch `origin/main` and `upstream/main`; review the full divergence before choosing any upstream
   sync strategy.
2. Inspect recent Actions runs and open PRs in `activeviam/symphony` and
   `activeviam/shared-infrastructure`; close superseded digest PRs only after verifying their diffs.
3. Verify the live Argo CD application, one Symphony deployment, five-agent configuration, Human
   Review CronJob, ECR digest, `/healthz` probes, target health, and internal dashboard.
4. Compare the authoritative deployed workflow with the examples in this repository and reconcile
   documentation drift before functional changes.
5. Run the isolated end-to-end ATRS acceptance described above and preserve the evidence.
6. Choose the next source track: upstream reconciliation, deployed acceptance lane, persistent
   workspaces/operational hardening, or the secure transcript viewer. The dashboard role/state
   indicator is the smallest useful UI follow-up.

Any source commit on `main`, including documentation-only commits, can trigger the tested-image
publisher and create a new digest-only pull request in `activeviam/shared-infrastructure`. Review
that generated PR, but do not merge or deploy it merely because this guide changed.

A useful opening prompt for a new Codex task is:

> Read ACTIVEVIAM.md completely. Re-check origin/main, upstream/main, the current GitHub Actions
> runs, `activeviam/shared-infrastructure`, the relevant infrastructure repositories, Jira ATRS,
> and the live read-only Shared EKS state. Treat dated runtime facts as a baseline, reconcile the
> fork with current upstream deliberately, and continue from the recommended next task without
> merging a pull request or changing the cluster directly unless I explicitly ask.
