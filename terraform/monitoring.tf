resource "kubernetes_namespace" "monitoring" {
  count = var.enable_monitoring ? 1 : 0
  metadata { name = "monitoring" }
}

resource "helm_release" "kube_prometheus_stack" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [module.eks, kubernetes_namespace.monitoring]

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1" # verified published; user confirms latest compatible at apply time
  namespace  = "monitoring"

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password != "" ? var.grafana_admin_password : null
      service       = { type = "ClusterIP" }
    }
    # Scrape the operator's metrics-exporter (:8888) and ClickHouse embedded endpoint (:9363)
    # via ServiceMonitors created by the operator/CHI. Discover across all namespaces.
    prometheus = {
      prometheusSpec = {
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }
  })]
}
