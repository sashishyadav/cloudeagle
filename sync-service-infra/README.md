# sync-service — GCP Infrastructure Design

> **Part 2 deliverable** — infrastructure setup for a Spring Boot + MongoDB service on GCP
> Focus: **auto-scaling** · **secure access** · **startup-friendly cost**

---

## 📁 Repository Layout

```
sync-service-infra/
├── README.md                           # Quick overview (this file)
├── docs/
│   ├── DESIGN.md                       # Full design document (read this)
│   ├── architecture.svg                # Architecture diagram
│   └── cost-estimate.md                # Monthly cost breakdown
├── terraform/
│   ├── modules/
│   │   ├── vpc/                        # VPC, subnets, NAT, firewalls
│   │   ├── compute/                    # MIG, instance template, autoscaler
│   │   ├── lb/                         # HTTPS LB + Cloud Armor
│   │   └── security/                   # IAM, Secret Manager, SAs
│   └── envs/
│       ├── qa/                         # QA-specific tfvars + backend
│       ├── staging/
│       └── prod/
└── scripts/
    ├── bootstrap.sh                    # One-time GCP project setup
    └── deploy-infra.sh                 # Plan + apply helper
```

---

## 🎯 Key Choices at a Glance

| Area | Chosen | Why |
|---|---|---|
| **Compute** | Compute Engine + MIG | Matches existing VM setup; cheapest for 24/7 workloads; simpler ops than GKE for one service |
| **MongoDB** | Atlas (managed, GCP Mumbai region) | Managed backups, HA out of the box, tiny ops burden — right tradeoff for a startup |
| **Networking** | Single VPC, regional subnets, Cloud NAT | Private VMs (no public IPs); external load balancer is the only ingress |
| **Secrets** | GCP Secret Manager + per-env SAs | Native IAM integration, rotation support, no extra infra |
| **Observability** | Cloud Logging + Cloud Monitoring via Ops Agent | Bundled cheap tier covers what a startup needs on day one |

---

## 📖 Read the Design Doc

**[`docs/DESIGN.md`](./docs/DESIGN.md)** — full written explanation covering:
- Compute platform tradeoffs (Cloud Run vs GKE vs Compute Engine)
- MongoDB self-hosted vs Atlas vs Cloud SQL
- Network topology and security boundaries
- IAM model and secret rotation flow
- Auto-scaling policies
- Monthly cost estimate

**[`docs/architecture.svg`](./docs/architecture.svg)** — architecture diagram

---

## 🚀 Deploying the Infrastructure

```bash
# One-time setup
./scripts/bootstrap.sh

# Per-env provisioning
cd terraform/envs/qa       # or staging / prod
terraform init
terraform plan -out=plan.out
terraform apply plan.out
```

---

*Designed for a pre-Series-A startup: keep it cheap, keep it simple, keep room to grow.*
