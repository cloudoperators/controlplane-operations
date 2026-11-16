# controlplane-gardener-alerting

Greenhouse plugin that integrates the **Gardener Prometheus alerting stack**
with a central alerting stack. It serves two purposes:

- **Alert rules targeting `garden` namespace Prometheus** — any rule that should
  evaluate on `garden` Prometheus rather than on another in-cluster Prometheus.
- **Routing bridge** — configures `garden` Prometheus (`garden/garden`) to forward
  alerts to a central Alertmanager with the required routing labels, and to run a
  Thanos sidecar for long-term metric storage.

Packaged as a separate plugin because its deployment target differs from the
`controlplane-operations` plugin — scoped to runtime clusters where the Gardener
operator runs.

## How it works

The Gardener operator owns the `garden/garden` Prometheus CR and reconciles it
continuously, so this chart's configuration cannot be written to the CR directly
— the operator would revert it. Instead this chart ships a set of
`MutatingAdmissionPolicy` (MAP) resources that mutate the operator's own
CREATE/UPDATE writes to the CR. Every reconcile re-applies the injected fields
(self-healing).

A MAP only fires on CREATE/UPDATE, and the operator has usually already created
the CR by the time this chart is installed. The rollout-trigger Job
(`rollout-trigger-job.yaml`) patches an annotation onto the CR on every chart
install/upgrade to force a fresh UPDATE so the MAPs apply immediately to the
existing object. No flag — it always runs when `map.enabled` is true.

### Rendered resources (all gated on `map.enabled`)

| Template | Purpose |
|---|---|
| `map-sci-routing.yaml` | MAP: injects `externalLabels`, `additionalAlertManagerConfigs`, `additionalAlertRelabelConfigs`, and the mTLS client-cert `secrets` entry into the CR. |
| `map-thanos.yaml` | MAPs: `gardener-prometheus-thanos` injects `spec.thanos` (sidecar image). `gardener-prometheus-thanos-objstore` injects and reconciles `objectStorageConfig` when `objectStorage.enabled`. `gardener-prometheus-thanos-objstore-cleanup` removes `objectStorageConfig` when `objectStorage.enabled` is `false`. |
| `secret-sci-alerting.yaml` | The mTLS client cert and the Alertmanager send-path config, in the `garden` namespace. |
| `secret-alert-relabel-configs.yaml` | The `additionalAlertRelabelConfigs` payload (support_group, playbook URL, severity downgrade). |
| `secret-thanos-objstore.yaml` | The Thanos objstore config Secret. Rendered only when `objectStorage.enabled`. |
| `network-policy-thanos-grpc.yaml` | Allows an external Thanos Query to reach the garden Prometheus sidecar on `:10901` (the `garden` namespace is deny-all). |
| `network-policy-rollout-trigger.yaml` | Egress for the rollout-trigger Job to the API server. |
| `rollout-trigger-job.yaml` | Post-install/post-upgrade Job (+ RBAC) that annotates the CR to activate the MAPs on every chart release. |

## Configuration

### `map` — Garden Prometheus mutation

| Key | Type | Default | Description |
|---|---|---|---|
| `map.enabled` | bool | `false` | Master switch. Enables the MAPs, Secrets, NetworkPolicies, and rollout Job. Everything in this chart is gated on it. |
| `map.externalLabels.cluster` | string | `""` | Runtime cluster name, merged into CR `spec.externalLabels`. Must be set per target. |
| `map.externalLabels.region` | string | `""` | Region, merged into `spec.externalLabels`. Must be set per target. |
| `map.externalLabels.cluster_type` | string | `""` | Cluster-type label, merged into `spec.externalLabels`. |
| `map.thanos.version` | string | `v0.42.4` | Thanos sidecar image tag injected into `spec.thanos`. Keep aligned with the monitoring stack's Thanos version. |
| `map.kubectl.version` | string | `v1.34.8` | kubectl image tag for the rollout-trigger Job. Pin to the runtime cluster's Kubernetes version. |

Gardener's own labels (e.g. `landscape`) are preserved — the `externalLabels`
mutation is a granular map merge, not a replace.

### `map.alertManager` — Alertmanager send path

| Key | Type | Description |
|---|---|---|
| `map.alertManager.secretName` | string | Secret name for `spec.additionalAlertManagerConfigs`. |
| `map.alertManager.key` | string | Key within the Secret. |
| `map.alertManager.targets` | list(string) | Central Alertmanager hostnames the alerts are sent to over mTLS. Set per deployment. |

### `map.relabel` — alert relabeling

| Key | Type | Description |
|---|---|---|
| `map.relabel.secretName` | string | Secret name for `spec.additionalAlertRelabelConfigs`. |
| `map.relabel.key` | string | Key within the Secret. |
| `map.relabel.playbookBaseURL` | string | Base URL for playbook links. The lowercased alertname is appended as the final path segment. |

The relabel Secret currently also downgrades `critical` severity to `warning`
while the alert path is being validated.

### Thanos Object Store Configuration

During region builds, object storage as required by Thanos long-term storage might
only become available at a later stage of the build-up. However, the observability
stack must deploy before it. For this reason, the Thanos integration is separated
into two phases:

**Phase 1 — early region (default).** `objectStorage.enabled: false`. The
sidecar starts, exposes StoreAPI on `:10901`, and Thanos Query sees current
data. No blocks are uploaded; there is no long-term retention yet.

**Phase 2 — storage available.** Flip `objectStorage.enabled: true` and supply
`objectStorage.config`. The phase-2 MAP (`gardener-prometheus-thanos-objstore`)
injects and reconciles `objectStorageConfig` in `spec.thanos` on every CR UPDATE.
The rollout-trigger Job runs on every chart upgrade, so the MAP applies
immediately after the chart deploy — no manual trigger needed.

> Note: The Thanos sidecar is always injected (via `map.thanos.version`), so Thanos
> Query can read **live** data from the garden Prometheus immediately.

| Key | Type | Default | Description |
|---|---|---|---|
| `objectStorage.enabled` | bool | `false` | When `false`, the sidecar runs StoreAPI-only (live data, no uploads). When `true`, a MAP injects and reconciles `spec.thanos.objectStorageConfig` on every CR UPDATE, and the objstore Secret is rendered. |
| `objectStorage.secretName` | string | | Name of the Secret in the `garden` namespace holding the objstore config. |
| `objectStorage.secretKey` | string | | Key within that Secret. |
| `objectStorage.config` | string | `""` | The Thanos [objstore config](https://github.com/thanos-io/objstore) content. Use secret references (resolved at deploy time) for credentials. |

**Disabling** (`objectStorage.enabled: false`) installs a cleanup MAP
(`gardener-prometheus-thanos-objstore-cleanup`) that removes
`spec.thanos.objectStorageConfig` on the next Gardener reconcile UPDATE,
preventing Prometheus from referencing the now-deleted Secret. No manual
`kubectl patch` needed.

## Minimal values for a new target

```yaml
map:
  enabled: true
  externalLabels:
    cluster: <cluster-name>
    region: <region>
    cluster_type: <cluster-type>

# phase 2 only — leave disabled until object storage is reachable
objectStorage:
  enabled: false
```
