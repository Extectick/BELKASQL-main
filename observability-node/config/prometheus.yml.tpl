global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090

  - job_name: etcd
    metrics_path: /metrics
    static_configs:
      - targets:
          - __CITY_A_HOST__:__CITY_A_ETCD_METRICS_PORT__
        labels:
          node: city-a
          role: etcd
      - targets:
          - __CITY_B_HOST__:__CITY_B_ETCD_METRICS_PORT__
        labels:
          node: city-b
          role: etcd
      - targets:
          - __CLOUD_CONTROL_HOST__:__CLOUD_CONTROL_ETCD_METRICS_PORT__
        labels:
          node: cloud-control
          role: etcd

  - job_name: postgres_exporter
    static_configs:
      - targets:
          - __CITY_A_HOST__:__CITY_A_POSTGRES_EXPORTER_PORT__
        labels:
          node: city-a
          role: postgres
      - targets:
          - __CITY_B_HOST__:__CITY_B_POSTGRES_EXPORTER_PORT__
        labels:
          node: city-b
          role: postgres

  - job_name: haproxy
    metrics_path: /metrics
    static_configs:
      - targets:
          - __CLOUD_LB_A_HOST__:__CLOUD_LB_A_METRICS_PORT__
        labels:
          node: cloud-lb-a
          role: haproxy
      - targets:
          - __CLOUD_LB_B_HOST__:__CLOUD_LB_B_METRICS_PORT__
        labels:
          node: cloud-lb-b
          role: haproxy

  - job_name: minio
    scheme: https
    metrics_path: /minio/v2/metrics/cluster
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets:
          - __MINIO_PRIMARY_HOST__:__MINIO_PRIMARY_API_PORT__
        labels:
          node: minio-primary
          role: minio
      - targets:
          - __MINIO_SECONDARY_HOST__:__MINIO_SECONDARY_API_PORT__
        labels:
          node: minio-secondary
          role: minio

  - job_name: node_exporter
    static_configs:
      - targets:
          - __CITY_A_HOST__:__CITY_A_NODE_EXPORTER_PORT__
        labels:
          node: city-a
          role: host
      - targets:
          - __CITY_B_HOST__:__CITY_B_NODE_EXPORTER_PORT__
        labels:
          node: city-b
          role: host
      - targets:
          - __CLOUD_CONTROL_HOST__:__CLOUD_CONTROL_NODE_EXPORTER_PORT__
        labels:
          node: cloud-control
          role: host
      - targets:
          - __CLOUD_LB_A_HOST__:__CLOUD_LB_A_NODE_EXPORTER_PORT__
        labels:
          node: cloud-lb-a
          role: host
      - targets:
          - __CLOUD_LB_B_HOST__:__CLOUD_LB_B_NODE_EXPORTER_PORT__
        labels:
          node: cloud-lb-b
          role: host
      - targets:
          - __MINIO_PRIMARY_HOST__:__MINIO_PRIMARY_NODE_EXPORTER_PORT__
        labels:
          node: minio-primary
          role: host
      - targets:
          - __MINIO_SECONDARY_HOST__:__MINIO_SECONDARY_NODE_EXPORTER_PORT__
        labels:
          node: minio-secondary
          role: host
