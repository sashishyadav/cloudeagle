# Infrastructure Design — sync-service on GCP

**Service:** Spring Boot REST API · **DB:** MongoDB · **Scale:** Early-stage startup
**Priorities:** Auto-scaling · Secure access · Reasonable cost

---

## Executive Summary

Run sync-service on **Compute Engine Managed Instance Groups (MIGs)** inside a private VPC, fronted by a **Global External HTTPS Load Balancer** with Cloud Armor. MongoDB is hosted on **MongoDB Atlas** (managed) connected via VPC peering. Secrets live in **GCP Secret Manager**; logs and metrics go to **Cloud Logging + Cloud Monitoring** via the Ops Agent.

This design intentionally trades a little operational sophistication (vs Kubernetes) for **lower cost, simpler day-2 ops, and faster iteration** — the right call for an early-stage startup.

Estimated monthly cost at steady-state: **~$350–500/month across all three environments** (see [cost estimate](./cost-estimate.md)).

---

## 1. Compute Platform

### Options Considered

| Option | Fit Score | Reasoning |
|---|---|---|
| **Cloud Run** | 6/10 | Serverless, cheap at low traffic, auto-scales from zero. But: cold starts on Spring Boot (~8-15s JVM warmup), max request duration caps, and the service maintains a persistent MongoDB connection pool — doesn't map well to a request-scoped model. |
| **GKE Standard** | 5/10 | Industry standard, great for multi-service architectures. But: control plane costs $72/month per cluster, operational complexity (networking, RBAC, Helm, upgrades), and this is a **single service** — Kubernetes' benefits don't kick in until you have 5+ services. |
| **GKE Autopilot** | 6/10 | Managed control plane, pay-per-pod. Lower ops burden than Standard, but still $0.10/vCPU-hour plus control plane. Overkill for one service. |
| **Compute Engine + MIG** | 9/10 | ✅ **Chosen.** Predictable monthly cost, simple mental model, direct integration with GCP LB/IAM/Secret Manager. Team already has VM operations experience from the Part 1 design. |
| **App Engine Standard** | 4/10 | Legacy feel; limited Java runtime options; less flexible than Cloud Run. Not chosen. |

### Why Compute Engine for This Service

1. **Cost at steady-state.** A single `e2-medium` ($24/month) running 24/7 beats Cloud Run once you're serving >3M requests/month, and it beats any GKE config once you factor in the control plane.

2. **No cold-start problem.** Spring Boot's JVM warmup (~8-15s) is painful on serverless. With MIGs, instances are always warm and ready.

3. **Persistent connections.** The service maintains a MongoDB connection pool of 10-50 connections per instance. Serverless models fight this — each request on Cloud Run may land on a fresh container, exhausting the DB pool.

4. **Team velocity.** The existing CI/CD design (Part 1) already targets MIGs. Migrating to GKE later is an option, but starting there adds 2-3 weeks of setup for zero benefit today.

5. **Debug-ability.** `gcloud compute ssh` onto a VM is simple. `kubectl exec` into a pod is simple too, but the additional context switch (namespace, pod name, container, logs command) adds friction when debugging under pressure.

### When to Reconsider

Reconsider **GKE** if any of these become true:
- You're running **5+ distinct services** (shared control plane starts paying off)
- You need **fine-grained pod-level autoscaling** (e.g., 100+ pods with varied resource shapes)
- Team has hired a **dedicated platform engineer**

Reconsider **Cloud Run** if:
- Traffic is **bursty / seasonal** with long idle periods
- You can refactor the service to be **stateless at the request level** (move the DB connection pooling logic server-side in the DB or via a PgBouncer-like proxy for Mongo)

---

## 2. Auto-Scaling

### Configuration

```
Managed Instance Group (per env):
  Initial size:   2 instances
  Min size:       2 (prod) / 1 (qa, staging)
  Max size:       10 (prod) / 4 (qa, staging)
  Cooldown:       60 seconds

Scaling policies (prod):
  CPU utilization target:     60%
  HTTP load balancer target:  800 req/sec per instance
  Scale-in control:           max 25% removal per 5-minute window
```

### Why these numbers?

- **60% CPU target** leaves headroom for JVM GC pauses and request spikes. At 80%+ you start seeing tail-latency issues.
- **Minimum of 2 in prod** ensures **availability during rolling or blue/green deploys** — with a min of 1, a single instance failure means a total outage.
- **Scale-in limited to 25% per 5 min** prevents the autoscaler from aggressively removing instances after a brief traffic lull and causing another scale-up 30 seconds later.
- **Health checks** are configured to test `/actuator/health/liveness` every 10s; 3 failures → instance replacement.

### Autoscaler Policy (Terraform excerpt)

```hcl
resource "google_compute_region_autoscaler" "sync_service" {
  name   = "sync-service-${var.environment}-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.sync_service.id

  autoscaling_policy {
    max_replicas    = var.max_replicas
    min_replicas    = var.min_replicas
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }

    load_balancing_utilization {
      target = 0.8
    }

    scale_in_control {
      max_scaled_in_replicas {
        percent = 25
      }
      time_window_sec = 300
    }
  }
}
```

---

## 3. MongoDB Hosting

### Options Considered

| Option | Verdict | Notes |
|---|---|---|
| **Self-hosted on Compute Engine** | ❌ Rejected | Requires you to handle: replica set setup, backups, upgrades, patching, monitoring, disaster recovery. 1 engineer-week/month easily. Startup ops burden unjustified. |
| **MongoDB Atlas (managed)** | ✅ **Chosen** | Managed backups, auto-failover, one-click upgrades, built-in monitoring. Integrates with GCP via VPC Peering or Private Service Connect. |
| **Google Cloud Firestore** | ❌ Rejected | Different data model (documents only, limited query expressiveness); service is already written against MongoDB; rewrite too costly. |
| **Google Cloud Spanner** | ❌ Rejected | Relational, not document-oriented. Doesn't fit. |
| **AWS DocumentDB via peering** | ❌ Rejected | Cross-cloud latency + egress charges. Not worth it. |

### Chosen Tier: Atlas M20

```
Tier:                M20 (on GCP, Mumbai region to match our service)
vCPU/RAM:            2 / 8 GB
Storage:             20 GB auto-scaling up to 128 GB
Replica set:         3 nodes (primary + 2 secondaries)
Backup:              Continuous, 24-hour point-in-time restore
VPC connection:      VPC Peering to sync-service-vpc
Estimated cost:      ~$180/month
```

**Why M20, not M10 or M30:**
- M10 ($60/month): 2 GB RAM — insufficient for working set of moderate document sizes
- M20 ($180/month): comfortable for 50-100 GB data, 500-1000 ops/sec
- M30 ($420/month): premature — upgrade when metrics demand it, not before

### Network Connection Pattern

```
sync-service VPC          VPC Peering         MongoDB Atlas VPC
    ┌─────────────────┐       ◄────►        ┌───────────────────┐
    │  10.0.0.0/20    │                     │  192.168.240.0/21 │
    │  MIG instances  │────── private ──────│  Replica set      │
    └─────────────────┘                     └───────────────────┘
```

- **No public IP access** to the database — Atlas is reachable only through the peered VPC
- **Authentication** via SCRAM (username/password from Secret Manager) + **IP allowlist** (Atlas side)
- **TLS** on all connections
- **Per-env separation** — each env has its own Atlas project + cluster, so QA can't accidentally hit prod data

### Atlas vs Self-Host Cost Comparison

| Item | Self-hosted (3 VMs) | Atlas M20 |
|---|---|---|
| Compute | 3 × e2-medium = $72 | included |
| Storage | 3 × 50GB SSD = $25 | included |
| Backups (to GCS) | $15 + engineering time | included |
| Monitoring | Ops Agent = free | included (Atlas built-in) |
| Ops overhead | ~20 engineer-hours/month @ $100/hr = **$2000** | ~2 hrs/month |
| **Total** | **~$2112/month** | **$180/month** |

Atlas wins by >10x at startup scale, and the gap narrows only after ~1TB of data.

---

## 4. Networking

### VPC Topology

```
Project: sync-service-${env}
└── VPC: sync-service-vpc
    │
    ├── Subnet: sync-service-subnet  (10.0.0.0/20, region asia-south1)
    │   ├── MIG instances (private IPs only)
    │   └── Proxy-only subnet for internal LB (if added later)
    │
    ├── Cloud NAT: sync-service-nat  (outbound internet access)
    │   └── Static external IP: <reserved>  (for 3rd-party IP allowlists)
    │
    ├── Firewall rules:
    │   ├── Allow LB health checks (35.191.0.0/16, 130.211.0.0/22) → :8080
    │   ├── Allow internal SSH via IAP (35.235.240.0/20) → :22
    │   └── Deny all else (implicit)
    │
    └── VPC Peering: atlas-peering  (to MongoDB Atlas VPC)
```

### Ingress (north-south traffic)

```
Internet
   │
   ▼
Cloud Armor (WAF + DDoS + rate limit)
   │
   ▼
Global External HTTPS LB
   │  (managed TLS cert, HTTP → HTTPS redirect)
   ▼
Backend Service → MIG
```

**Why Global External HTTPS LB:**
- **Free managed TLS certs** (Google-managed, auto-renewing)
- **Built-in Cloud Armor integration** for WAF and rate limiting
- **Anycast IP** — global edge termination, even if the backend is regional
- **Backend-aware health checks** — only routes to healthy instances
- Cost: ~$18/month per forwarding rule + $0.008/GB processed — negligible at startup scale

### Egress (north-south outbound)

- Instances have **no public IPs**
- All outbound traffic routes through **Cloud NAT** with a **static external IP**
- The static IP is given to third parties who need to allowlist our traffic

### East-West (inside VPC)

- MIG instances → MongoDB Atlas: via **VPC Peering** (private, no hops)
- MIG instances → Secret Manager / Artifact Registry / Cloud Logging: via **Private Google Access** (no NAT hop, no egress charges)

---

## 5. Security & IAM

### Service Account Model (Least Privilege)

| Service Account | Purpose | Permissions |
|---|---|---|
| `sa-sync-service-qa@...` | QA runtime | Read QA secrets, write QA logs/metrics, pull QA images |
| `sa-sync-service-staging@...` | Staging runtime | Same, staging-scoped |
| `sa-sync-service-prod@...` | Prod runtime | Same, prod-scoped |
| `sa-jenkins-deploy@...` | CI/CD deploys | Push images, update MIGs, flip LB backends |
| `sa-developers@...` (group) | Human debugging | Read logs, SSH via IAP, read (not write) secrets in qa only |

**Key principle:** The QA service account cannot read prod secrets, and vice versa. Even if a QA VM is compromised, prod data is not exposed.

### IAM Policy Highlights

```hcl
# QA runtime: can only read QA-scoped secrets
resource "google_secret_manager_secret_iam_member" "qa_mongo_uri" {
  secret_id = "sync-service-mongo-uri-qa"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:sa-sync-service-qa@${project}.iam.gserviceaccount.com"
}

# Developers: can SSH only via Identity-Aware Proxy (no public SSH ports)
resource "google_iap_tunnel_instance_iam_binding" "dev_ssh" {
  instance = each.value
  role     = "roles/iap.tunnelResourceAccessor"
  members  = ["group:developers@acme.com"]
}
```

### Secret Management

**Structure:**
```
projects/sync-service-prod/secrets/
├── sync-service-mongo-uri-prod          # mongodb+srv://user:pass@...
├── sync-service-api-key-prod            # 3rd-party API key
└── sync-service-jwt-signing-key-prod    # JWT HMAC secret
```

**Retrieval at runtime** (done in VM startup script):
```bash
MONGO_URI=$(gcloud secrets versions access latest \
    --secret=sync-service-mongo-uri-${ENVIRONMENT})
export MONGO_URI
systemctl start sync-service
```

**Rotation:** Cloud Scheduler fires a Cloud Function monthly to rotate non-DB secrets. MongoDB password rotation is manual (quarterly) via Atlas UI.

### Defense in Depth

1. **Cloud Armor** — WAF rules (SQL injection, XSS), rate limit 1000 req/min per IP
2. **HTTPS LB** — TLS 1.2 min, HSTS enabled, HTTP auto-redirects to HTTPS
3. **VPC firewall** — deny-by-default; only LB health checks and IAP SSH allowed
4. **Cloud NAT egress** — instances can't receive unsolicited inbound traffic
5. **IAM** — least-privilege SAs, no long-lived access keys
6. **Secret Manager** — secrets never in VM metadata, Terraform state, or logs
7. **VPC Service Controls** (optional, for prod) — prevent data exfiltration from Secret Manager and GCS

---

## 6. Observability

### Stack

| Component | Tool | Cost |
|---|---|---|
| **Logs** | Cloud Logging (via Ops Agent) | Free tier: 50 GB/month ingestion; $0.50/GB thereafter |
| **Metrics** | Cloud Monitoring (via Ops Agent + Micrometer) | Free tier: generous; custom metrics $0.258/M data points |
| **Traces** | Cloud Trace (via Spring Cloud Sleuth) | 2.5M spans/month free |
| **Uptime checks** | Cloud Monitoring | 1M checks/month free |
| **Alerting** | Cloud Monitoring → PagerDuty + Slack | Included |

### What's Instrumented

**Logs:**
- Structured JSON via Logback + `logstash-logback-encoder`
- Shipped by the Ops Agent (no app-level integration needed)
- Retention: 30 days (qa/staging), 90 days (prod)

**Metrics:**
- **System:** CPU, memory, disk, network (Ops Agent default)
- **JVM:** heap usage, GC pauses, thread count (Micrometer JMX)
- **App:** request rate, error rate, P50/P95/P99 latency (Micrometer HTTP)
- **MongoDB:** pool utilization, connection count, query latency (Micrometer MongoDB)

**Alerts:**

| Condition | Threshold | Severity | Channel |
|---|---|---|---|
| Prod error rate | >1% for 5 min | P0 | PagerDuty + Slack |
| Prod P95 latency | >2s for 10 min | P1 | PagerDuty + Slack |
| MongoDB pool exhausted | >90% for 2 min | P0 | PagerDuty |
| Instance health check failing | Any | P1 | Slack |
| Cost anomaly | >20% MoM | P2 | Email |

### Dashboards (defined in Terraform)

1. **Service overview** — request rate, error rate, latency percentiles, instance count
2. **JVM health** — heap, GC frequency, thread pool stats
3. **MongoDB** — connection pool, query latency, replica lag
4. **Cost** — daily spend by service, forecast vs budget

---

## 7. Cost Summary (Monthly Estimate)

See [`cost-estimate.md`](./cost-estimate.md) for itemized breakdown.

| Environment | Monthly Cost |
|---|---|
| **QA** | ~$80 |
| **Staging** | ~$90 |
| **Prod** | ~$250 |
| **Shared** (Artifact Registry, Atlas, monitoring) | ~$250 |
| **Total** | **~$670/month** |

At current startup scale, this is dominated by:
1. MongoDB Atlas M20 — $180
2. Prod MIG (min 2 instances `n2-standard-2`) — ~$100
3. Staging + QA MIGs — ~$60
4. HTTPS LB + Cloud Armor — ~$30

### Cost Optimizations (Day 1)

- Use **e2-medium** for QA/staging (cheaper burstable)
- **n2-standard-2** for prod (consistent performance)
- **Spot (Preemptible) instances for QA** — 70% discount, acceptable for non-critical env
- **Committed-use discounts** for prod — 37% off when you commit to 1 year
- **Cloud Armor** only enabled on prod initially — QA/staging direct LB is fine

### Cost Optimizations (Growth)

- Move to **GKE** once you have 5+ services (amortize the control plane)
- **Regional persistent disks** → **zonal SSD** where durability matters less
- **Log filter policies** — exclude `/actuator/*` traffic from Cloud Logging to stay under free tier

---

## 8. Disaster Recovery

| Scenario | Recovery |
|---|---|
| Single VM failure | Auto-replaced by MIG autohealing (~2 min) |
| Single zone failure | Traffic routes to healthy zone (regional MIG across zone-a + zone-b) |
| Full region failure | Manual failover to backup region (Terraform modules parameterize the region) — RPO 15min, RTO ~1hr |
| MongoDB data loss | Atlas point-in-time restore to any second within 24hr |
| Accidental deletion | Terraform state in GCS with object versioning; `terraform state pull` can restore |
| Compromised SA key | Revoke in IAM console; rotate all affected secrets via Secret Manager |

---

## 9. What I'd NOT Do (And Why)

- ❌ **Multi-region active-active** — premature; adds 3x complexity for a startup with no customers in multiple regions yet.
- ❌ **Istio / service mesh** — single service, no need for mTLS, traffic shaping, etc. Plain LB + HTTPS is plenty.
- ❌ **Custom AMIs** — debian-12 + startup script is enough. Image bakes add CI complexity.
- ❌ **Self-managed Prometheus + Grafana** — Cloud Monitoring covers 95% of what a startup needs. Migrate if you outgrow it.
- ❌ **Kubernetes NetworkPolicies / Calico / Linkerd** — N/A (no K8s).
- ❌ **Terraform Cloud / Atlantis** — manual `terraform apply` from a trusted workstation is fine until there are 3+ infra engineers.

These aren't "bad" tools — they're tools whose cost (complexity, time, money) doesn't yet match the benefit for this use case.

---

## Appendix: Environment-Specific Sizes

| Resource | QA | Staging | Prod |
|---|---|---|---|
| VM type | e2-medium (preemptible) | e2-medium | n2-standard-2 |
| MIG min | 1 | 1 | 2 |
| MIG max | 4 | 4 | 10 |
| MongoDB Atlas | Shared M10 | Shared M10 | Dedicated M20 |
| Cloud Armor | ❌ | ❌ | ✅ |
| Log retention | 30 days | 30 days | 90 days |
| Alerts → PagerDuty | ❌ | ❌ | ✅ |

---

*Document version 1.0 — April 2026*
