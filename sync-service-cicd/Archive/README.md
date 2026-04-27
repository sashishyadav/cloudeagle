# sync-service — CI/CD Pipeline Design

> **Spring Boot** backend • **MongoDB** • **GCP VMs** • **Jenkins**
> Environments: **qa** → **staging** → **prod**

Complete CI/CD design for a Spring Boot service that deploys to GCP VMs across three environments with zero-downtime deployment to production.

---

## 📁 Repository Layout

```
sync-service-cicd/
├── README.md                          # This file — project overview
├── docs/
│   └── DESIGN.md                      # Full design document (read this)
├── jenkins/
│   └── Jenkinsfile                    # Production-ready pipeline
├── config/
│   ├── application.yml                # Shared Spring Boot config
│   ├── application-qa.yml             # QA overrides
│   ├── application-staging.yml        # Staging overrides
│   └── application-prod.yml           # Prod overrides (no secrets)
├── scripts/
│   ├── deploy-blue-green.sh           # Blue/green deploy script
│   ├── deploy-rolling.sh              # Rolling deploy script
│   ├── rollback.sh                    # Manual rollback helper
│   └── smoke-test.sh                  # Post-deploy health check
├── Dockerfile                         # Multi-stage Spring Boot image
└── .github/
    └── CODEOWNERS                     # Branch protection ownership
```

---

## 🚦 At a Glance

| Environment | Branch | Deploy Strategy | Approval Gate |
|---|---|---|---|
| **QA** | `develop` | Rolling | Auto on merge |
| **Staging** | `release/*` | Blue/Green | Auto on merge |
| **Prod** | `main` (tagged) | Blue/Green | Manual approval |

---

## 🎯 Key Design Decisions

### 1. Branching Strategy
GitFlow-adjacent, with `develop` → QA, `release/*` → Staging, `main` → Prod.
`main` is protected, requires 2 reviewers, and only deploys when a semver tag is pushed (not on every merge).

### 2. Jenkins Pipeline
10-stage declarative pipeline. PRs run CI only (build + test + SonarQube). Merges run CI + deploy. Prod requires a manual `input()` step.

### 3. Secrets Handling
**Zero secrets in source control.** All sensitive values (MongoDB URI, API keys) in GCP Secret Manager, with per-environment paths and least-privilege IAM.

### 4. Deployment Strategy: Blue/Green
Chosen over Rolling and Recreate because:
- True **zero downtime** (LB switch, not gradual rollout)
- **Instant rollback** — flip LB backend, no redeploy needed
- Avoids MongoDB connection pool churn during rollouts

QA uses simpler Rolling deploys to save cost.

---

## 🚀 Getting Started

1. **Read [`docs/DESIGN.md`](./docs/DESIGN.md)** for the full rationale
2. **Review [`jenkins/Jenkinsfile`](./jenkins/Jenkinsfile)** for the pipeline
3. **Configure Jenkins** credentials (see design doc)
4. **Provision GCP resources** (instance groups, LBs, Secret Manager)
5. **Open a PR** on `develop` to verify CI works end-to-end

---

## 📖 Full Documentation

See **[`docs/DESIGN.md`](./docs/DESIGN.md)** for:
- Alternative approaches considered (and why rejected)
- IAM policies needed
- Rollback flows (automatic + manual)
- Observability setup (logs, metrics, alerts)
- GCP resource topology

---

*Built for Spring Boot 3.x + Java 17 + GCP Compute Engine*
