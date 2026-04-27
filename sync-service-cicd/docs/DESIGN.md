# CI/CD Design Document — sync-service

**Spring Boot · MongoDB · GCP VMs · Jenkins**
**Environments:** qa · staging · prod

---

## Table of Contents

1. [Branching Strategy](#1-branching-strategy)
2. [Jenkins Pipeline](#2-jenkins-pipeline)
3. [Configuration Management](#3-configuration-management)
4. [Deployment Strategy](#4-deployment-strategy)
5. [Rollback Strategy](#5-rollback-strategy)
6. [Observability](#6-observability)
7. [GCP Resource Topology](#7-gcp-resource-topology)

---

## 1. Branching Strategy

### Branch → Environment Mapping

```
feature/*   ──► (no auto-deploy; PR only runs CI)
develop     ──► QA         (auto-deploy on merge)
release/*   ──► Staging    (auto-deploy on merge)
main        ──► Prod       (manual approval + semver tag required)
hotfix/*    ──► Prod       (emergency path; merges to both main and develop)
```

### Branch Lifecycle

```
                                            ┌─────────┐
                                            │  main   │───► PROD (tag push)
                                            └────▲────┘
                                                 │
                                            ┌────┴─────┐
                                            │ release/*│───► STAGING
                                            └────▲─────┘
                                                 │
  ┌─────────────┐    ┌─────────────┐    ┌────┴─────┐
  │ feature/foo │───►│ feature/bar │───►│  develop │───► QA
  └─────────────┘    └─────────────┘    └──────────┘
```

### Protection Rules

| Branch | Direct Push | Min Approvals | Required Checks | Who Can Merge |
|---|---|---|---|---|
| `main` | ❌ No | 2 | CI green + signed-off staging | Team Lead or Senior Eng |
| `release/*` | ❌ No | 1 | CI green + QA sign-off | Any engineer |
| `develop` | ❌ No | 1 | CI green | Any engineer |
| `feature/*` | ✅ Yes (own branch) | N/A | CI green for PR | Owner |

### Options Considered

| Strategy | Pros | Cons | Verdict |
|---|---|---|---|
| **Trunk-based** (single main branch) | Simple, fast CI/CD cycle | No natural staging environment, harder to gate prod | ❌ Not enough separation for 3 environments |
| **GitFlow (classic)** | Clear release train | Heavy, long-lived release branches, prone to merge hell | ⚠️ Too heavy for a single service |
| **GitHub Flow** (feature → main) | Modern, lightweight | Only one environment by default | ❌ Doesn't map to QA/Staging/Prod cleanly |
| **GitFlow-adjacent** (this design) | Clear env mapping, short-lived release branches, protected main | Slightly more ceremony than trunk-based | ✅ **Chosen** |

### Avoiding Accidental Prod Deployments

Defense in depth — **four layers**:

1. **Branch protection** — `main` has no direct push; every change arrives via PR
2. **Tag-triggered prod deploys** — merging to `main` alone doesn't deploy; a semver tag (`v1.2.3`) must be pushed
3. **Manual Jenkins approval** — pipeline pauses at a human `input()` step before touching prod
4. **Concurrency lock** — a GCP Secret Manager flag (`deploy-lock-prod`) prevents two prod deploys running simultaneously
5. **Audit trail** — Jenkins captures the approver's identity; every deploy is traceable to a human

---

## 2. Jenkins Pipeline

### High-Level Stages

```
┌──────────┐  ┌─────────┐  ┌──────────┐  ┌──────────────┐  ┌──────────┐
│ Checkout │─►│ Compile │─►│   Test   │─►│ SonarQube    │─►│  Build   │
└──────────┘  └─────────┘  └──────────┘  └──────────────┘  │  Image   │
                            │                               └────┬─────┘
                            ▼                                    │
                       [Unit + IT]                               ▼
                                                          ┌──────────────┐
                                                          │ Push to      │
                                                          │ Artifact Reg │
                                                          └──────┬───────┘
                                                                 │
                                                                 ▼
                                                          ┌──────────────┐
                                                          │    Deploy    │
                                                          │ (env-aware)  │
                                                          └──────┬───────┘
                                                                 │
                                                                 ▼
                                                          ┌──────────────┐
                                                          │  Smoke Test  │
                                                          └──────┬───────┘
                                                                 │
                                                  ┌──────────────┼─────────┐
                                                  ▼                        ▼
                                            ┌──────────┐          ┌──────────────┐
                                            │ Finalize │          │  Rollback    │
                                            │ (LB flip)│          │  (on fail)   │
                                            └──────────┘          └──────────────┘
```

### What Runs When

| Event | Stages Executed | Deploys? |
|---|---|---|
| PR opened/updated | Checkout → Compile → Test → SonarQube | ❌ No |
| Merge to `develop` | All stages | ✅ QA (rolling, auto) |
| Merge to `release/*` | All stages | ✅ Staging (blue/green, auto) |
| Tag `v*.*.*` on `main` | All stages | ✅ Prod (blue/green, **manual gate**) |

### PR Behavior Details

On every PR push, Jenkins runs:

1. **Checkout** the PR branch (with the merge commit against target)
2. **Compile** — catches syntax errors fast (fails in <30s for bad code)
3. **Unit tests** — JUnit/Mockito, minimum 70% coverage enforced via JaCoCo
4. **Integration tests** — Testcontainers spins up ephemeral MongoDB, runs Spring Boot tests against it
5. **SonarQube** — code quality gate (bugs, security, code smell thresholds enforced)

If any stage fails, the PR is blocked from merging via GitHub Checks integration.

### Prod Gate Details

When a `v*.*.*` tag is pushed to `main`:

```groovy
stage('Deploy to Prod') {
    steps {
        notifySlack("⏳ Prod deployment ready — awaiting approval")
        timeout(time: 30, unit: 'MINUTES') {
            input(
                message: "Deploy ${IMAGE_TAG} to PRODUCTION?",
                ok: 'Deploy to Prod',
                submitterParameter: 'APPROVER'
            )
        }
        blueGreenDeploy('prod')
    }
}
```

- A Slack notification goes to `#deployments` when the gate opens
- Approval times out after 30 minutes (prevents stale gate-holds)
- The approver's username is captured into `APPROVER` env var and logged
- Only users in the `sync-service-prod-deployers` GitHub team can approve (enforced via Jenkins role-based auth)

---

## 3. Configuration Management

### Env-Specific Config via Spring Profiles

```
src/main/resources/
├── application.yml              ← shared defaults
├── application-qa.yml           ← QA-specific overrides
├── application-staging.yml      ← Staging-specific overrides
└── application-prod.yml         ← Prod-specific overrides
```

Active profile set at startup:
```bash
java -jar sync-service.jar --spring.profiles.active=prod
```

**What lives in `application-*.yml`:**
- ✅ Log levels (`logging.level.root=INFO` for prod, `DEBUG` for qa)
- ✅ Thread pool sizes (`spring.task.execution.pool.core-size=20`)
- ✅ Feature flags (`features.new-sync-algorithm.enabled=true`)
- ✅ Timeouts, retry counts, circuit breaker thresholds

**What does NOT live in these files:**
- ❌ Any secret (MongoDB URI, API key, JWT signing key)
- ❌ Any credential
- ❌ Any internal URL that could leak architecture

### Secrets Handling — GCP Secret Manager

**Structure:**
```
projects/acme-prod/secrets/
├── sync-service-mongo-uri-qa
├── sync-service-mongo-uri-staging
├── sync-service-mongo-uri-prod
├── sync-service-api-key-qa
├── sync-service-api-key-staging
├── sync-service-api-key-prod
└── sync-service-jwt-signing-key-prod
```

**IAM model (least-privilege):**
- Each env's GCP VM service account gets `roles/secretmanager.secretAccessor` **only for its env's secrets**
- The staging SA cannot read `sync-service-mongo-uri-prod`
- Jenkins's SA can read all envs (needed to inject at deploy time) but is tightly audited

**Injection at runtime:**

Approach 1 — **Startup script fetches secrets** (chosen):
```bash
# Runs on VM startup via instance template metadata
MONGO_URI=$(gcloud secrets versions access latest \
    --secret="sync-service-mongo-uri-${ENVIRONMENT}")
export MONGO_URI

systemctl start sync-service
```

Approach 2 — **Spring Cloud GCP Secret Manager** (alternative):
```yaml
# application-prod.yml
spring:
  cloud:
    gcp:
      secretmanager:
        enabled: true
        secrets:
          - sm://sync-service-mongo-uri-prod
```
App reads secrets directly on boot. Cleaner but adds a hard dependency on Spring Cloud GCP.

**Rotation:**
- Cloud Scheduler job rotates the API key every 90 days
- MongoDB connection string rotates on DB password changes (manual for now, quarterly cadence)
- Old secret versions kept for 30 days to enable rollback

### Options Considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **`.env` files in repo** | Simple | Leaks secrets; no rotation | ❌ Never |
| **Jenkins credentials plugin only** | Built into Jenkins | Single point of failure; hard to rotate | ⚠️ Used only for Jenkins' own creds (e.g., GCP SA key) |
| **HashiCorp Vault** | Industry standard, powerful | Operational overhead (run Vault cluster) | ⚠️ Overkill for single service |
| **GCP Secret Manager** | Native to GCP, IAM integration | GCP-locked | ✅ **Chosen** |
| **Spring Cloud Config Server** | Centralized Spring config | Another service to run; still needs backing store | ❌ Indirection without benefit |

---

## 4. Deployment Strategy

### Options Compared

| Strategy | Downtime | Rollback Speed | Resource Cost | Risk | Complexity |
|---|---|---|---|---|---|
| **Recreate** | ❌ Full outage (seconds-minutes) | Moderate (redeploy) | Low (1x) | High | Low |
| **Rolling** | ⚠️ Minimal (brief pool churn) | Moderate (redeploy) | Medium (1.25x during roll) | Medium | Medium |
| **Blue/Green** | ✅ Zero | ⚡ Instant (LB flip) | High (2x during deploy) | Low | Medium |
| **Canary** | ✅ Zero | ⚡ Instant | Medium-High | Very Low | High |

### Chosen: **Blue/Green** for Staging + Prod, **Rolling** for QA

#### Why Blue/Green for Prod?

1. **MongoDB connection pool hygiene.** The service maintains a persistent pool (~50 connections/instance). Rolling restarts cause the pool to churn — old instances close connections while new ones open them. On a loaded service this can spike MongoDB's connection count to 2-3x normal briefly. Blue/green avoids this entirely: the new pool warms up in isolation, then takes over traffic all at once.

2. **Instant rollback.** If we deploy bad code and the smoke test catches it, we flip the load balancer back to the old (still-running) blue instance group in ~5 seconds. With rolling, we'd need to redeploy the old version, which takes minutes — during which users are seeing errors.

3. **Cleaner observability.** All traffic is on one version at any moment. If metrics spike post-deploy, there's no ambiguity about which version is responsible.

#### Why Rolling for QA?

1. **Cost.** QA doesn't need 2x instances. Rolling uses 1.25x momentarily, 1x at rest.
2. **Tolerance.** QA users are internal; 30 seconds of request errors mid-deploy is acceptable.
3. **Simplicity.** Easier to iterate on when deploys happen 10-20x per day.

#### Why NOT Canary?

1. Added complexity: traffic-splitting logic, metrics-based auto-promotion, per-cohort observability
2. `sync-service` is a **stateless API** — no gradual rollout is needed for user-experience reasons
3. Our traffic volume doesn't justify the infra investment for canary analysis
4. Blue/green already gives us 90% of canary's safety benefit at much lower complexity

### Blue/Green Flow (Prod)

```
[Initial state]
    GCP LB ──► Blue (v1.4.2) [100% traffic]
              Green (idle)

[Step 1: Build new instance template with v1.4.3]
    gcloud compute instance-templates create ...

[Step 2: Update Green instance group to new template]
    GCP LB ──► Blue (v1.4.2) [100% traffic]
              Green (v1.4.3) [warming up]

[Step 3: Smoke test Green directly via its internal IP]
    curl http://green-internal:8080/actuator/health
    # Must pass for 5 consecutive checks

[Step 4: Flip LB backend service]
    GCP LB ──► Blue (v1.4.2) [draining, 30s]
              Green (v1.4.3) [100% traffic]

[Step 5: Wait 10 minutes (rollback window)]
    GCP LB ──► Green (v1.4.3) [100% traffic]
              Blue (v1.4.2) [still warm, ready to flip back]

[Step 6: Decommission Blue]
    GCP LB ──► Green (v1.4.3) [100% traffic]
              Blue (scaled to 0)

[Next deploy: colors swap — Blue becomes the new-version target]
```

### Zero-Downtime Requirements

All of the following must be in place for blue/green to deliver true zero-downtime:

- [x] **Graceful shutdown** — `server.shutdown=graceful` + `spring.lifecycle.timeout-per-shutdown-phase=30s`
- [x] **LB connection draining** — 30s timeout so in-flight requests complete
- [x] **Health check endpoints** — `/actuator/health/liveness` and `/actuator/health/readiness` (separate!)
- [x] **Startup probe tolerance** — LB waits 60s before first health check (allows JVM warmup)
- [x] **MongoDB pool sized per instance** — `maxPoolSize=50`, `minPoolSize=10`
- [x] **Idempotent API semantics** — safe to retry if a request fails mid-switch

---

## 5. Rollback Strategy

### Automatic Rollback (on smoke test failure)

```groovy
post {
    failure {
        script {
            if (env.ENVIRONMENT && env.PREV_IMAGE) {
                deployRollback(env.ENVIRONMENT, env.PREV_IMAGE)
                notifySlack("🔴 Deploy failed; auto-rolled back to ${env.PREV_IMAGE}")
            }
        }
    }
}
```

For **blue/green** deployments, rollback is a single LB-backend flip — no redeploy needed, old instances are still warm. Takes ~5 seconds.

For **rolling** deployments (QA), rollback re-applies the previous instance template — takes ~2 minutes.

### Manual Rollback

A separate parameterized Jenkins job:

```
Job: sync-service/rollback
  Parameters:
    - ENVIRONMENT : [qa | staging | prod]
    - IMAGE_TAG   : <previous tag to restore>
```

Used when:
- Smoke tests passed but real-world monitoring shows problems
- A bug manifests only after the 10-minute post-deploy window closes
- A rollback decision is made from incident response rather than deploy pipeline

### Why NOT Continuous Deployment to Prod?

I deliberately chose **continuous delivery** (deploy automation, manual trigger) over **continuous deployment** (automatic on every merge) for prod because:

1. Business changes (pricing, promotions, legal) sometimes need human timing decisions
2. Customer-visible changes deserve a human in the loop
3. Engineers on-call should know when a deploy is about to hit prod

QA and staging *are* continuous deployment — every merge goes out automatically.

---

## 6. Observability

### Logging
- **Library:** Logback + `logstash-logback-encoder` for structured JSON logs
- **Destination:** GCP Cloud Logging (via Fluent Bit on each VM)
- **Retention:** 30 days QA/Staging, 90 days Prod
- **PII scrubbing:** Logback filter strips email, phone, credit-card patterns before export

### Metrics
- **Library:** Micrometer with GCP Monitoring registry
- **Key metrics:** JVM heap, request rate, error rate, P50/P95/P99 latency, MongoDB pool stats
- **Dashboards:** Published as code (Terraform `google_monitoring_dashboard`)

### Tracing
- **Library:** Spring Cloud Sleuth + Google Cloud Trace
- **Sampling:** 100% in QA, 10% in Staging, 1% in Prod

### Alerts
| Condition | Severity | Channel |
|---|---|---|
| Prod error rate > 1% for 5 min | P0 | PagerDuty + Slack |
| Prod P95 latency > 2s for 10 min | P1 | PagerDuty + Slack |
| MongoDB connection pool exhausted | P0 | PagerDuty + Slack |
| Staging smoke test failing after deploy | P2 | Slack only |
| Deploy succeeded | Info | Slack |

---

## 7. GCP Resource Topology

```
GCP Project: acme-sync-service
│
├── Artifact Registry
│   └── us-central1-docker.pkg.dev/acme/sync-service/
│       ├── sync-service:abc123-42           # git-sha + build-num
│       ├── sync-service:latest-qa
│       ├── sync-service:latest-staging
│       └── sync-service:latest-prod
│
├── Secret Manager
│   ├── sync-service-mongo-uri-{qa,staging,prod}
│   ├── sync-service-api-key-{qa,staging,prod}
│   └── sync-service-jwt-signing-key-{qa,staging,prod}
│
├── Compute Engine
│   ├── Instance Templates
│   │   ├── sync-service-qa-template
│   │   ├── sync-service-staging-blue-template
│   │   ├── sync-service-staging-green-template
│   │   ├── sync-service-prod-blue-template
│   │   └── sync-service-prod-green-template
│   │
│   └── Managed Instance Groups
│       ├── sync-service-qa          (3 instances, rolling updates)
│       ├── sync-service-staging-blue  (3 instances)
│       ├── sync-service-staging-green (3 instances)
│       ├── sync-service-prod-blue   (6 instances, n2-standard-4)
│       └── sync-service-prod-green  (6 instances, n2-standard-4)
│
├── Load Balancing
│   ├── sync-service-qa-lb       → qa MIG
│   ├── sync-service-staging-lb  → blue OR green MIG (flipped on deploy)
│   └── sync-service-prod-lb     → blue OR green MIG (flipped on deploy)
│
├── VPC & Networking
│   ├── Cloud NAT            (for outbound traffic from private instances)
│   └── Firewall rules       (LB health checks, SSH via IAP only)
│
└── Cloud Monitoring & Logging
    ├── Uptime checks        (all 3 envs)
    ├── Alerting policies    (PagerDuty integration)
    └── Custom dashboards    (per-env and aggregate)
```

---

## Appendix: Jenkins Credentials Required

| Credential ID | Type | Purpose |
|---|---|---|
| `gcp-sa-key` | Secret File | GCP service account JSON key |
| `slack-webhook-url` | Secret Text | Deploy notification webhook |
| `sonar-token` | Secret Text | SonarQube authentication |
| `github-token` | Secret Text | For commit-status updates |
| `mongodb-test-uri` | Secret Text | Ephemeral test DB URI (Testcontainers doesn't need) |

---

*Last updated: April 2026 — Document version 1.0*
