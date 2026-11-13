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
the CR by the time this chart is installed. The one-time rollout-trigger Job
(`map.rolloutTriggerJob.enabled`) patches an annotation onto the CR to force a
fresh UPDATE so the MAPs apply to the existing object. After the first rollout
it can be disabled.

### Rendered resources (all gated on `map.enabled`)

| Template | Purpose |
|---|---|
| `map-sci-routing.yaml` | MAP: injects `externalLabels`, `additionalAlertManagerConfigs`, `additionalAlertRelabelConfigs`, and the mTLS client-cert `secrets` entry into the CR. |
| `map-thanos.yaml` | MAP: injects `spec.thanos` (sidecar image). A second MAP injects `objectStorageConfig` when `objectStorage.enabled`. |
| `secret-sci-alerting.yaml` | The mTLS client cert and the Alertmanager send-path config, in the `garden` namespace. |
| `secret-alert-relabel-configs.yaml` | The `additionalAlertRelabelConfigs` payload (support_group, playbook URL, severity downgrade). |
| `secret-thanos-objstore.yaml` | The Thanos objstore config Secret. Rendered only when `objectStorage.enabled`. |
| `network-policy-thanos-grpc.yaml` | Allows an external Thanos Query to reach the garden Prometheus sidecar on `:10901` (the `garden` namespace is deny-all). |
| `network-policy-rollout-trigger.yaml` | Egress for the rollout-trigger Job to the API server. Gated also on `map.rolloutTriggerJob.enabled`. |
| `rollout-trigger-job.yaml` | One-time Job (+ RBAC) that annotates the CR to activate the MAPs. Gated also on `map.rolloutTriggerJob.enabled`. |

## Configuration

### `map` — Garden Prometheus mutation

| Key | Type | Default | Description |
|---|---|---|---|
| `map.enabled` | bool | `false` | Master switch. Enables the MAPs, Secrets, NetworkPolicies, and rollout Job. Everything in this chart is gated on it. |
| `map.rolloutTriggerJob.enabled` | bool | `true` | Deploy the post-install/post-upgrade trigger Job that activates the MAP. **One-time use** — set to `false` once the initial rollout is complete. |
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

### `objectStorage` — Thanos long-term storage (two-phase)

The Thanos sidecar is always injected (via `map.thanos.version`), so Thanos
Query can read **live** data from the garden Prometheus immediately. Uploading
blocks to object storage is a separate, later phase: the object storage cluster
may not be reachable early in a region build-up, but the observability stack
must deploy before it. This block gates that second phase.

| Key | Type | Default | Description |
|---|---|---|---|
| `objectStorage.enabled` | bool | `false` | When `false`, the sidecar runs StoreAPI-only (live data, no uploads). When `true`, a second MAP injects `spec.thanos.objectStorageConfig` and the objstore Secret is rendered. |
| `objectStorage.secretName` | string | | Name of the Secret in the `garden` namespace holding the objstore config. |
| `objectStorage.secretKey` | string | | Key within that Secret. |
| `objectStorage.config` | string | `""` | The Thanos [objstore config](https://github.com/thanos-io/objstore) content. Use secret references (resolved at deploy time) for credentials. |

**Phase 1 — early region (default).** `objectStorage.enabled: false`. The
sidecar starts, exposes StoreAPI on `:10901`, and Thanos Query sees current
data. No blocks are uploaded; there is no long-term retention yet.

**Phase 2 — storage available.** Flip `objectStorage.enabled: true` and supply
`objectStorage.config`. The second MAP adds `objectStorageConfig` to the
already-injected `spec.thanos`, the sidecar begins uploading blocks, and the
Store Gateway serves history. No other change is needed — the two MAPs chain by
CEL match condition (phase 1 fires when `spec.thanos` is absent; phase 2 fires
when `spec.thanos` exists but lacks `objectStorageConfig`).

The `objectStorage.config` value is a Thanos objstore config document (see the
[supported providers](https://github.com/thanos-io/objstore)); supply
credentials as deploy-time secret references rather than inline literals.

## Minimal values for a new target

```yaml
map:
  enabled: true
  rolloutTriggerJob:
    enabled: true   # set false after the first successful rollout
  externalLabels:
    cluster: <cluster-name>
    region: <region>
    cluster_type: <cluster-type>

# phase 2 only — leave disabled until object storage is reachable
objectStorage:
  enabled: false
```
