#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


class ConfigError(Exception):
    pass


PLACEHOLDER_RE = re.compile(r"(^|[-_])replace-with|example\.com|example\.internal|monitoring\.example\.com", re.IGNORECASE)
NODE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def strip_comment(line: str) -> str:
    quote = None
    out = []
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).rstrip()


def parse_scalar(value: str) -> Any:
    value = value.strip()
    if value == "":
        return ""
    if value in ("true", "True"):
        return True
    if value in ("false", "False"):
        return False
    if value in ("null", "None", "~"):
        return None
    if value.startswith('"') and value.endswith('"'):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    return value


def split_key_value(text: str) -> tuple[str, Any]:
    if ":" not in text:
        raise ConfigError(f"expected key: value, got: {text}")
    key, value = text.split(":", 1)
    key = key.strip()
    if not key:
        raise ConfigError(f"empty key in line: {text}")
    return key, parse_scalar(value)


def load_simple_yaml(path: Path) -> dict[str, Any]:
    raw_lines: list[tuple[int, str]] = []
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw.strip() == "" or raw.lstrip().startswith("#"):
            continue
        line = strip_comment(raw)
        if line.strip() == "":
            continue
        indent = len(line) - len(line.lstrip(" "))
        raw_lines.append((indent, line.strip()))

    def parse_block(index: int, indent: int) -> tuple[Any, int]:
        if index >= len(raw_lines):
            return {}, index

        current_indent, current_text = raw_lines[index]
        if current_indent < indent:
            return {}, index
        if current_indent != indent:
            raise ConfigError(f"unexpected indentation near: {current_text}")

        if current_text.startswith("- "):
            items = []
            while index < len(raw_lines):
                line_indent, text = raw_lines[index]
                if line_indent < indent:
                    break
                if line_indent != indent or not text.startswith("- "):
                    break

                item_text = text[2:].strip()
                index += 1
                if item_text == "":
                    child, index = parse_block(index, indent + 2)
                    items.append(child)
                elif ":" in item_text:
                    key, value = split_key_value(item_text)
                    item = {key: value}
                    if index < len(raw_lines) and raw_lines[index][0] > indent:
                        child, index = parse_block(index, indent + 2)
                        if not isinstance(child, dict):
                            raise ConfigError(f"list item child must be a map near: {item_text}")
                        item.update(child)
                    items.append(item)
                else:
                    items.append(parse_scalar(item_text))
                    if index < len(raw_lines) and raw_lines[index][0] > indent:
                        raise ConfigError(f"scalar list item cannot have children: {item_text}")
            return items, index

        result: dict[str, Any] = {}
        while index < len(raw_lines):
            line_indent, text = raw_lines[index]
            if line_indent < indent:
                break
            if line_indent != indent:
                raise ConfigError(f"unexpected indentation near: {text}")
            if text.startswith("- "):
                break
            key, value = split_key_value(text)
            index += 1
            if value == "" and index < len(raw_lines) and raw_lines[index][0] > indent:
                value, index = parse_block(index, indent + 2)
            result[key] = value
        return result, index

    parsed, index = parse_block(0, 0)
    if index != len(raw_lines):
        raise ConfigError(f"could not parse line: {raw_lines[index][1]}")
    if not isinstance(parsed, dict):
        raise ConfigError("top-level config must be a map")
    return parsed


def truthy(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def kebab(name: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", name.strip().lower()).strip("-")


def upper_key(name: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")


def env_text(values: dict[str, Any]) -> str:
    lines = [
        "# Generated by ./belkasql generate. Do not edit this file by hand.",
    ]
    for key, value in values.items():
        if value is True:
            value = "true"
        elif value is False:
            value = "false"
        elif value is None:
            value = ""
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


def default_ip(base: int, index: int, offset: int) -> str:
    return f"172.28.0.{base + index * 10 + offset}"


def node_label(node: dict[str, Any]) -> str:
    return str(node["name"])


def etcd_name(node: dict[str, Any]) -> str:
    return str(node.get("etcd_name") or f"etcd-{node_label(node)}")


def patroni_etcd_hosts_for(node: dict[str, Any], etcd_nodes: list[dict[str, Any]]) -> list[str]:
    local = [n for n in etcd_nodes if n["name"] == node["name"]]
    remote = [n for n in etcd_nodes if n["name"] != node["name"]]
    ordered = local + remote
    return [etcd_name(n) if n["name"] == node["name"] else str(n["host"]) for n in ordered]


def validate(config: dict[str, Any]) -> None:
    nodes = config.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        raise ConfigError("nodes must be a non-empty list")
    seen = set()
    seen_hosts = set()
    for node in nodes:
        if not isinstance(node, dict):
            raise ConfigError("each node must be a map")
        for key in ("name", "host"):
            if key not in node:
                raise ConfigError(f"node is missing {key}: {node}")
        name = str(node["name"])
        host = str(node["host"])
        if not NODE_NAME_RE.fullmatch(name):
            raise ConfigError(f"node name must be lowercase kebab-case: {name}")
        if name in seen:
            raise ConfigError(f"duplicate node name: {name}")
        seen.add(name)
        if host in seen_hosts:
            raise ConfigError(f"duplicate node host: {host}")
        seen_hosts.add(host)

    etcd_nodes = [n for n in nodes if truthy(n.get("etcd"))]
    if len(etcd_nodes) != 3:
        raise ConfigError("exactly 3 etcd nodes are required by current Patroni template")
    if not [n for n in nodes if truthy(n.get("postgres"))]:
        raise ConfigError("at least one postgres node is required")


def find_placeholders(value: Any, path: str = "") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}" if path else str(key)
            found.extend(find_placeholders(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(find_placeholders(child, f"{path}[{index}]"))
    elif isinstance(value, str) and PLACEHOLDER_RE.search(value):
        found.append(path)
    return found


def validate_production(config: dict[str, Any]) -> None:
    validate(config)

    errors: list[str] = []
    placeholders = find_placeholders(config)
    if placeholders:
        errors.append("placeholder/example values remain: " + ", ".join(sorted(placeholders)))

    required_paths = [
        ("etcd.token", config.get("etcd", {}).get("token")),
        ("backup.bucket", config.get("backup", {}).get("bucket")),
        ("backup.endpoint", config.get("backup", {}).get("endpoint")),
        ("backup.key", config.get("backup", {}).get("key")),
        ("backup.secret", config.get("backup", {}).get("secret")),
        ("postgres.superuser_password", config.get("postgres", {}).get("superuser_password")),
        ("postgres.replication_password", config.get("postgres", {}).get("replication_password")),
        ("postgres.app_user_password", config.get("postgres", {}).get("app_user_password")),
    ]
    if truthy(config.get("observability", {}).get("enabled")):
        required_paths.append(("observability.grafana_admin_password", config.get("observability", {}).get("grafana_admin_password")))
    if truthy(config.get("load_balancer", {}).get("enabled")) and truthy(config.get("load_balancer", {}).get("keepalived_enabled"), True):
        required_paths.append(("load_balancer.keepalived_auth_pass", config.get("load_balancer", {}).get("keepalived_auth_pass")))

    for path, value in required_paths:
        if value is None or str(value).strip() == "":
            errors.append(f"missing production value: {path}")

    db_nodes = [n for n in config["nodes"] if truthy(n.get("postgres"))]
    for node in db_nodes:
        if str(node.get("host")) in {"127.0.0.1", "localhost", "0.0.0.0"}:
            errors.append(f"postgres node has non-routable host: {node['name']}")

    generated = build(config)
    generated_placeholders = []
    for rel_path, content in generated.items():
        for line in content.splitlines():
            if "=" in line and PLACEHOLDER_RE.search(line):
                generated_placeholders.append(f"{rel_path}:{line.split('=', 1)[0]}")
    if generated_placeholders:
        errors.append("generated env still contains placeholders: " + ", ".join(sorted(generated_placeholders)))

    if errors:
        raise ConfigError("; ".join(errors))


def build(config: dict[str, Any]) -> dict[Path, str]:
    validate(config)
    cluster = config.get("cluster", {})
    ports = config.get("ports", {})
    etcd = config.get("etcd", {})
    backup = config.get("backup", {})
    postgres = config.get("postgres", {})
    observability = config.get("observability", {})
    lb = config.get("load_balancer", {})
    nodes = config["nodes"]

    patroni_scope = cluster.get("patroni_scope", "belka-ha")
    network = cluster.get("docker_network", "belkasql_belka-net")
    preferred = cluster.get("preferred_primary", "")
    db_nodes = [n for n in nodes if truthy(n.get("postgres"))]
    etcd_nodes = [n for n in nodes if truthy(n.get("etcd"))]
    etcd_cluster = ",".join(f"{etcd_name(n)}=http://{n['host']}:{etcd.get('peer_port', 2380)}" for n in etcd_nodes)
    first_db = db_nodes[0]
    preferred_node = next((n for n in db_nodes if n["name"] == preferred), first_db)
    output: dict[Path, str] = {}

    for index, node in enumerate(db_nodes):
        name = node_label(node)
        project = kebab(name)
        other = preferred_node if preferred_node["name"] != node["name"] else next((n for n in db_nodes if n["name"] != node["name"]), preferred_node)
        patroni_etcd_hosts = patroni_etcd_hosts_for(node, etcd_nodes)
        values = {
            "COMPOSE_PROJECT_NAME": project,
            "BELKA_NETWORK_NAME": network,
            "INTERNAL_BIND_IP": node["host"],
            "ETCD_HEARTBEAT_INTERVAL": etcd.get("heartbeat_interval", 2000),
            "ETCD_ELECTION_TIMEOUT": etcd.get("election_timeout", 10000),
            "ETCD_CLIENT_PUBLISHED_PORT": etcd.get("client_port", 2379),
            "ETCD_CONTAINER_NAME": etcd_name(node),
            "ETCD_HOSTNAME": etcd_name(node),
            "ETCD_NAME": etcd_name(node),
            "ETCD_ADVERTISE_HOST": node["host"],
            "ETCD_IP": node.get("etcd_ip", default_ip(20, index, 3)),
            "ETCD_CLUSTER_TOKEN": etcd.get("token", "replace-with-etcd-token"),
            "ETCD_INITIAL_CLUSTER": etcd_cluster,
            "ETCD_INITIAL_CLUSTER_STATE": "existing" if not truthy(node.get("etcd")) else "new",
            "DB_CONTAINER_NAME": f"{project}-db",
            "DB_HOSTNAME": f"{project}-db",
            "DB_IP": node.get("db_ip", default_ip(20, index, 1)),
            "NODE_NAME": f"{project}-db",
            "NODE_API_HOST": node["host"],
            "NODE_PG_HOST": node["host"],
            "PATRONI_SCOPE": patroni_scope,
            "PATRONI_API_PUBLISHED_PORT": node.get("patroni_api_port", ports.get("patroni_api", 8008)),
            "PGBOUNCER_PUBLISHED_PORT": node.get("pgbouncer_port", ports.get("pgbouncer", 6432)),
            "LOCAL_LB_CONTAINER_NAME": f"{project}-local-lb",
            "LOCAL_LB_HOSTNAME": f"{project}-local-lb",
            "LOCAL_LB_IP": node.get("local_lb_ip", default_ip(20, index, 2)),
            "LOCAL_LB_WRITE_PUBLISHED_PORT": ports.get("local_write", 5000),
            "LOCAL_LB_READ_PUBLISHED_PORT": ports.get("local_read", 5001),
            "POSTGRES_EXPORTER_CONTAINER_NAME": f"{project}-postgres-exporter",
            "POSTGRES_EXPORTER_PUBLISHED_PORT": node.get("postgres_exporter_port", ports.get("postgres_exporter", 9187)),
            "POSTGRES_EXPORTER_IP": node.get("postgres_exporter_ip", default_ip(70, index, 3)),
            "NODE_EXPORTER_CONTAINER_NAME": f"{project}-node-exporter",
            "NODE_EXPORTER_PUBLISHED_PORT": node.get("node_exporter_port", ports.get("node_exporter", 9100)),
            "NODE_EXPORTER_IP": node.get("node_exporter_ip", default_ip(70, index, 4)),
            "PROMTAIL_CONTAINER_NAME": f"{project}-promtail",
            "PROMTAIL_NODE_LABEL": name,
            "PROMTAIL_ROLE_LABEL": "db-node",
            "PROMTAIL_IP": node.get("promtail_ip", default_ip(70, index, 5)),
            "LOKI_PUSH_URL": node.get("loki_push_url", f"http://{observability.get('host', 'monitoring.example.com')}:3100/loki/api/v1/push"),
            "LOCAL_DB_HOST": f"{project}-db",
            "REMOTE_DB_HOST": other["host"],
            "LOCAL_DB_DOMAIN": node.get("local_domain", f"db-{project}.internal"),
            "ETCD_HOST_1": patroni_etcd_hosts[0],
            "ETCD_HOST_2": patroni_etcd_hosts[1],
            "ETCD_HOST_3": patroni_etcd_hosts[2],
            "BACKREST_STANZA": backup.get("stanza", "belka"),
            "BACKREST_S3_BUCKET": backup.get("bucket", "replace-with-s3-bucket"),
            "BACKREST_S3_ENDPOINT": backup.get("endpoint", "replace-with-s3-endpoint"),
            "BACKREST_S3_KEY": backup.get("key", "replace-with-s3-access-key"),
            "BACKREST_S3_SECRET": backup.get("secret", "replace-with-s3-secret-key"),
            "BACKREST_S3_REGION": backup.get("region", "us-east-1"),
            "BACKREST_S3_PORT": backup.get("port", 9000),
            "BACKREST_S3_VERIFY_TLS": "y" if truthy(backup.get("verify_tls")) else "n",
            "POSTGRES_SUPERUSER_PASSWORD": postgres.get("superuser_password", "replace-with-strong-postgres-password"),
            "REPLICATION_PASSWORD": postgres.get("replication_password", "replace-with-strong-replication-password"),
            "APP_USER_PASSWORD": postgres.get("app_user_password", "replace-with-strong-app-password"),
        }
        output[Path("db-node") / "env" / f"{project}.env"] = env_text(values)

    for index, node in enumerate(n for n in nodes if truthy(n.get("etcd")) and not truthy(n.get("postgres"))):
        name = node_label(node)
        project = kebab(name)
        values = {
            "COMPOSE_PROJECT_NAME": project,
            "BELKA_NETWORK_NAME": network,
            "INTERNAL_BIND_IP": node["host"],
            "ETCD_HEARTBEAT_INTERVAL": etcd.get("heartbeat_interval", 2000),
            "ETCD_ELECTION_TIMEOUT": etcd.get("election_timeout", 10000),
            "ETCD_CLIENT_PUBLISHED_PORT": etcd.get("client_port", 2379),
            "ETCD_CONTAINER_NAME": etcd_name(node),
            "ETCD_HOSTNAME": etcd_name(node),
            "ETCD_NAME": etcd_name(node),
            "ETCD_ADVERTISE_HOST": node["host"],
            "ETCD_IP": node.get("etcd_ip", default_ip(10, index, 3)),
            "ETCD_CLUSTER_TOKEN": etcd.get("token", "replace-with-etcd-token"),
            "ETCD_INITIAL_CLUSTER": etcd_cluster,
            "NODE_EXPORTER_CONTAINER_NAME": f"{project}-node-exporter",
            "NODE_EXPORTER_PUBLISHED_PORT": node.get("node_exporter_port", ports.get("node_exporter", 9100)),
            "NODE_EXPORTER_IP": node.get("node_exporter_ip", default_ip(70, index, 1)),
            "PROMTAIL_CONTAINER_NAME": f"{project}-promtail",
            "PROMTAIL_NODE_LABEL": name,
            "PROMTAIL_ROLE_LABEL": "control-node",
            "PROMTAIL_IP": node.get("promtail_ip", default_ip(70, index, 2)),
            "LOKI_PUSH_URL": node.get("loki_push_url", f"http://{observability.get('host', 'monitoring.example.com')}:3100/loki/api/v1/push"),
        }
        output[Path("control-node") / "env" / f"{project}.env"] = env_text(values)

    if truthy(lb.get("enabled")):
        db_nodes_value = " ".join(f"{node_label(n)}={n['host']}" for n in db_nodes)
        keepalived_enabled = truthy(lb.get("keepalived_enabled"), True)
        values = {
            "COMPOSE_PROJECT_NAME": lb.get("compose_project_name", "cloud-lb-a"),
            "BELKA_NETWORK_NAME": network,
            "INTERNAL_BIND_IP": lb.get("internal_bind_ip", lb.get("host", "0.0.0.0")),
            "KEEPALIVED_ENABLED": str(keepalived_enabled).lower(),
            "LB_CONTAINER_NAME": lb.get("container_name", "cloud-lb-a"),
            "LB_HOSTNAME": lb.get("hostname", "cloud-lb-a"),
            "LB_NAME": lb.get("name", "cloud-lb-a"),
            "LB_IP": lb.get("container_ip", "172.28.0.91"),
            "KEEPALIVED_STATE": lb.get("keepalived_state", "MASTER"),
            "KEEPALIVED_PRIORITY": lb.get("keepalived_priority", 150),
            "KEEPALIVED_PEER_IP": lb.get("keepalived_peer_ip", "127.0.0.1"),
            "KEEPALIVED_VIP": lb.get("keepalived_vip", lb.get("host", "127.0.0.1")),
            "KEEPALIVED_AUTH_PASS": lb.get("keepalived_auth_pass", "replace-with-keepalived-password" if keepalived_enabled else ""),
            "DB_WRITE_DOMAIN": lb.get("write_domain", "db-write.internal"),
            "DB_READ_DOMAIN": lb.get("read_domain", "db-read.internal"),
            "DB_NODES": db_nodes_value,
            "LB_WRITE_PUBLISHED_PORT": lb.get("write_port", 5000),
            "LB_READ_PUBLISHED_PORT": lb.get("read_port", 5001),
            "LB_METRICS_PUBLISHED_PORT": lb.get("metrics_port", 8404),
            "NODE_EXPORTER_CONTAINER_NAME": lb.get("node_exporter_container_name", "cloud-lb-a-node-exporter"),
            "NODE_EXPORTER_PUBLISHED_PORT": lb.get("node_exporter_port", 9102),
            "NODE_EXPORTER_IP": lb.get("node_exporter_ip", "172.28.0.92"),
            "PROMTAIL_CONTAINER_NAME": lb.get("promtail_container_name", "cloud-lb-a-promtail"),
            "PROMTAIL_NODE_LABEL": lb.get("promtail_node_label", "cloud-lb-a"),
            "PROMTAIL_ROLE_LABEL": "lb-node",
            "PROMTAIL_IP": lb.get("promtail_ip", "172.28.0.93"),
            "LOKI_PUSH_URL": lb.get("loki_push_url", f"http://{observability.get('host', 'monitoring.example.com')}:3100/loki/api/v1/push"),
        }
        output[Path("lb-node") / "env" / "cloud-lb-a.env"] = env_text(values)

    if truthy(observability.get("enabled")):
        cloud_etcd_scrape_host = observability.get("cloud_control_etcd_scrape_host", "")
        cloud_node_scrape_host = observability.get("cloud_control_node_exporter_scrape_host", "")
        cloud_lb_a_host = observability.get("cloud_lb_a_host", "")
        etcd_targets = " ".join(
            f"{node_label(n)}={n['host']}:{etcd.get('client_port', 2379)}"
            for n in etcd_nodes
            if not (n.get("role") == "control" and cloud_etcd_scrape_host)
        )
        postgres_targets = " ".join(f"{node_label(n)}={n['host']}:{n.get('postgres_exporter_port', ports.get('postgres_exporter', 9187))}" for n in db_nodes)
        node_targets = " ".join(
            f"{node_label(n)}={n['host']}:{n.get('node_exporter_port', ports.get('node_exporter', 9100))}"
            for n in nodes
            if truthy(n.get("monitoring"), True) and not (n.get("role") == "control" and cloud_node_scrape_host)
        )
        haproxy_targets = ""
        if truthy(lb.get("enabled")) and not cloud_lb_a_host:
            haproxy_targets = f"{lb.get('name', 'cloud-lb-a')}={lb.get('host')}:{lb.get('metrics_port', 8404)}"
        values = {
            "COMPOSE_PROJECT_NAME": "cloud-observability",
            "BELKA_NETWORK_NAME": network,
            "INTERNAL_BIND_IP": observability.get("internal_bind_ip", observability.get("host", "0.0.0.0")),
            "PROMETHEUS_CONTAINER_NAME": "observability-prometheus",
            "PROMETHEUS_HOSTNAME": "observability-prometheus",
            "PROMETHEUS_PUBLISHED_PORT": observability.get("prometheus_port", 9090),
            "LOKI_CONTAINER_NAME": "observability-loki",
            "LOKI_HOSTNAME": "observability-loki",
            "LOKI_PUBLISHED_PORT": observability.get("loki_port", 3100),
            "ALERTMANAGER_CONTAINER_NAME": "observability-alertmanager",
            "ALERTMANAGER_HOSTNAME": "observability-alertmanager",
            "ALERTMANAGER_PUBLISHED_PORT": observability.get("alertmanager_port", 9093),
            "GRAFANA_CONTAINER_NAME": "observability-grafana",
            "GRAFANA_HOSTNAME": "observability-grafana",
            "GRAFANA_PUBLISHED_PORT": observability.get("grafana_port", 3000),
            "GRAFANA_ADMIN_USER": observability.get("grafana_admin_user", "admin"),
            "GRAFANA_ADMIN_PASSWORD": observability.get("grafana_admin_password", "replace-with-strong-grafana-password"),
            "GRAFANA_ROOT_URL": observability.get("grafana_root_url", "http://monitoring.example.com:3000"),
            "ETCD_TARGETS": etcd_targets,
            "POSTGRES_TARGETS": postgres_targets,
            "NODE_EXPORTER_TARGETS": node_targets,
            "HAPROXY_TARGETS": haproxy_targets,
            "BACKUP_METRICS_TARGETS": observability.get("backup_metrics_targets", ""),
            "CLOUD_CONTROL_HOST": observability.get("host", ""),
            "CLOUD_CONTROL_ETCD_SCRAPE_HOST": cloud_etcd_scrape_host,
            "CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST": cloud_node_scrape_host,
            "CLOUD_CONTROL_ETCD_METRICS_PORT": etcd.get("client_port", 2379),
            "CLOUD_CONTROL_NODE_EXPORTER_PORT": ports.get("node_exporter", 9100),
            "CLOUD_LB_A_HOST": cloud_lb_a_host,
            "CLOUD_LB_A_METRICS_PORT": observability.get("cloud_lb_a_metrics_port", ""),
            "CLOUD_LB_A_NODE_EXPORTER_PORT": observability.get("cloud_lb_a_node_exporter_port", ""),
            "CLOUD_LB_B_HOST": "",
            "CLOUD_LB_B_METRICS_PORT": "",
            "CLOUD_LB_B_NODE_EXPORTER_PORT": "",
            "MINIO_PRIMARY_HOST": observability.get("host", ""),
            "MINIO_PRIMARY_API_SCRAPE_HOST": observability.get("minio_primary_api_scrape_host", ""),
            "MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST": observability.get("minio_primary_node_exporter_scrape_host", ""),
            "MINIO_PRIMARY_API_PORT": 9000,
            "MINIO_PRIMARY_NODE_EXPORTER_PORT": observability.get("minio_primary_node_exporter_port", 9101),
            "MINIO_SECONDARY_HOST": "",
            "MINIO_SECONDARY_API_SCRAPE_HOST": "",
            "MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST": "",
            "MINIO_SECONDARY_API_PORT": "",
            "MINIO_SECONDARY_NODE_EXPORTER_PORT": "",
        }
        output[Path("observability-node") / "env" / "cloud-observability.env"] = env_text(values)

    return output


def write_outputs(outputs: dict[Path, str], out_dir: Path, dry_run: bool) -> None:
    for rel_path, content in sorted(outputs.items(), key=lambda item: str(item[0])):
        target = out_dir / rel_path
        if dry_run:
            print(f"--- {rel_path} ---")
            print(content, end="")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        print(f"generated {rel_path}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate BELKASQL env files from cluster.yml")
    parser.add_argument("config", nargs="?", default="cluster.yml")
    parser.add_argument("--out", default=str(ROOT), help="output project directory")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    config_path = Path(args.config)
    if not config_path.is_absolute():
        config_path = Path.cwd() / config_path
    if not config_path.exists():
        raise ConfigError(f"config not found: {config_path}")

    config = load_simple_yaml(config_path)
    outputs = build(config)
    write_outputs(outputs, Path(args.out), args.dry_run)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ConfigError as exc:
        print(f"belkasql generate: {exc}", file=sys.stderr)
        raise SystemExit(2)
