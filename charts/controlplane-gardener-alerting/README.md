# controlplane-gardener-alerting

Greenhouse plugin that integrates the **Gardener Prometheus alerting stack**
with **SCI alerting stack**. It serves two purposes:

- **Alert rules targeting `garden` namespace Prometheus** — any rule that should evaluate
  on Garden Prometheus rather than on the in-cluster kube-monitoring Prometheus.
- **Routing bridge** — configures Garden Prometheus (`garden/garden`) to
  forward alerts to SCI Alertmanager with the required routing labels.

Packaged as a separate plugin because its deployment target differs from the
`controlplane-operations` plugin — scoped to runtime clusters where the
Gardener operator runs.
