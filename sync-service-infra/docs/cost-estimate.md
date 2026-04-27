# Monthly Cost Estimate — sync-service on GCP

> Prices as of April 2026, `asia-south1` (Mumbai) region, on-demand.
> All figures USD. Real bills vary with data volume and usage patterns.

---

## Summary

| Environment | Total Monthly Cost |
|---|---|
| **Production** | ~$250 |
| **Staging** | ~$90 |
| **QA** | ~$80 |
| **Shared resources** | ~$250 |
| **Grand total** | **~$670** |

---

## Production

| Item | Quantity | Unit Cost | Monthly |
|---|---|---|---|
| n2-standard-2 VMs (MIG, avg 3 running) | 3 × 730 hrs | $0.0970/hr | $212 |
| Persistent SSD (20 GB × 3) | 60 GB | $0.17/GB | $10 |
| Global HTTPS LB | 1 forwarding rule | $18 + usage | $18 |
| Cloud Armor | 1 policy + rules | $5 + $0.75/rule | $10 |
| **Prod subtotal** | | | **~$250** |

## Staging

| Item | Quantity | Unit Cost | Monthly |
|---|---|---|---|
| e2-medium VMs (MIG, avg 2 running) | 2 × 730 hrs | $0.0335/hr | $49 |
| Persistent SSD (10 GB × 2) | 20 GB | $0.17/GB | $3.40 |
| Global HTTPS LB | 1 forwarding rule | $18 | $18 |
| Monitoring + logs (within free tier) | — | — | $0 |
| VPC peering to Atlas | — | — | $0 |
| **Staging subtotal** | | | **~$70** |

Plus a fraction of Atlas-shared-tier usage: ~$20 → **~$90**

## QA

| Item | Quantity | Unit Cost | Monthly |
|---|---|---|---|
| e2-medium preemptible VMs (MIG, avg 2) | 2 × 730 hrs | $0.01/hr | $15 |
| Persistent SSD (10 GB × 2) | 20 GB | $0.17/GB | $3.40 |
| Global HTTPS LB | 1 forwarding rule | $18 | $18 |
| **QA subtotal** | | | **~$36** |

Plus ~$20 Atlas shared + ~$20 misc → **~$80**

## Shared Resources

| Item | Cost |
|---|---|
| MongoDB Atlas M20 (prod, dedicated, 3-node RS) | $180 |
| MongoDB Atlas M0 shared (qa + staging, 1 each) | $0 (free tier) |
| Artifact Registry (Docker images, ~20 GB) | $2 |
| Secret Manager (< 10 secrets per env) | <$1 |
| Cloud Logging (within free tier) | $0 |
| Cloud Monitoring (within free tier) | $0 |
| Cloud Trace (within free tier) | $0 |
| Cloud NAT (per-env) | 3 × ~$15 | $45 |
| Cloud DNS zones (3 envs) | $1.50 |
| Static external IPs (for NAT + LB) | ~$15 |
| **Shared subtotal** | **~$250** |

---

## Growth Projections

| Traffic Level | Prod Monthly Cost |
|---|---|
| Current (100 req/sec avg, 6 instances peak) | $250 |
| 10× (1,000 req/sec, 10-15 instances peak) | $900 |
| 100× (10,000 req/sec, 40+ instances, DB upgrade to M40) | $5,500 |

**Key break-points:**
- At ~5,000 req/sec sustained, consider migrating to GKE (better bin-packing)
- At ~1TB data volume, consider Atlas M40 ($1,500/month) — still cheaper than self-hosting
- At 10× scale, committed-use discounts (1-year) save ~$300/month on compute

---

## Cost Controls

**Built-in:**
- BigQuery billing export → custom dashboard
- Budget alerts at 50%, 90%, 100% of monthly target
- Per-env labels on all resources → cost breakdown by environment

**Policy:**
- Developers need manager approval for resources costing >$50/month
- Any resource without a `cost_center` label fails Terraform validation
- Unused preemptible QA instances auto-terminate after 2hr of no requests

---

## When to Re-Evaluate

Review this estimate quarterly, or when:
- Monthly bill drifts >20% from estimate (investigate before paying)
- A new compute type is announced (arm instances, new machine families)
- Traffic doubles (time to revisit instance sizing)
