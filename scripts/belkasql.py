#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from belkasql_generate import ConfigError, build, load_simple_yaml, truthy, validate, validate_production


ROOT = Path(__file__).resolve().parents[1]


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def load_config(path_arg: str) -> tuple[Path, dict[str, Any]]:
    path = Path(path_arg)
    if not path.is_absolute():
        path = Path.cwd() / path
    if not path.exists():
        raise ConfigError(f"config not found: {path}")
    config = load_simple_yaml(path)
    secrets_path = path.with_name("secrets.yml")
    if secrets_path.exists():
        config = deep_merge(config, load_simple_yaml(secrets_path))
    return path, config


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def run(cmd: list[str], cwd: Path | None = None, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    )


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


def write_lock(config_path: Path, outputs: dict[Path, str], out_dir: Path) -> None:
    digest = hashlib.sha256()
    for rel_path, content in sorted(outputs.items(), key=lambda item: str(item[0])):
        digest.update(str(rel_path).encode("utf-8"))
        digest.update(b"\0")
        digest.update(content.encode("utf-8"))
        digest.update(b"\0")
    lock = {
        "config": str(config_path),
        "generated_at": int(time.time()),
        "sha256": digest.hexdigest(),
        "files": [str(path) for path in sorted(outputs)],
    }
    (out_dir / "cluster.lock").write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")


def cmd_generate(args: argparse.Namespace) -> int:
    config_path, config = load_config(args.config)
    outputs = build(config)
    out_dir = Path(args.out)
    write_outputs(outputs, out_dir, args.dry_run)
    if not args.dry_run:
        write_lock(config_path, outputs, out_dir)
        print("generated cluster.lock")
    return 0


def require_tool(name: str) -> bool:
    return shutil.which(name) is not None


def check_compose(config_path: Path, config: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="belkasql-check-") as tmp:
      tmp_path = Path(tmp)
      outputs = build(config)
      write_outputs(outputs, tmp_path, dry_run=False)

      copies = [
          "db-node/docker-compose.yml",
          "db-node/docker-compose.replica.yml",
          "control-node/docker-compose.yml",
          "lb-node/docker-compose.yml",
          "observability-node/docker-compose.yml",
      ]
      for item in copies:
          src = ROOT / item
          dst = tmp_path / item
          dst.parent.mkdir(parents=True, exist_ok=True)
          shutil.copy2(src, dst)

      checks: list[tuple[str, list[str], Path]] = []
      for env_file in sorted((tmp_path / "db-node/env").glob("*.env")):
          text = env_file.read_text(encoding="utf-8")
          compose = "docker-compose.yml" if "ETCD_INITIAL_CLUSTER_STATE=new" in text else "docker-compose.replica.yml"
          checks.append((f"compose db {env_file.name}", ["docker", "compose", "--env-file", str(env_file), "-f", str(tmp_path / "db-node" / compose), "config"], ROOT))

      for env_file in sorted((tmp_path / "control-node/env").glob("*.env")):
          checks.append((f"compose control {env_file.name}", ["docker", "compose", "--env-file", str(env_file), "-f", str(tmp_path / "control-node/docker-compose.yml"), "config"], ROOT))

      lb_env = tmp_path / "lb-node/env/cloud-lb-a.env"
      if lb_env.exists():
          checks.append(("compose lb", ["docker", "compose", "--env-file", str(lb_env), "-f", str(tmp_path / "lb-node/docker-compose.yml"), "config"], ROOT))

      obs_env = tmp_path / "observability-node/env/cloud-observability.env"
      if obs_env.exists():
          checks.append(("compose observability", ["docker", "compose", "--env-file", str(obs_env), "-f", str(tmp_path / "observability-node/docker-compose.yml"), "config"], ROOT))

      if require_tool("docker"):
          for label, command, cwd in checks:
              result = run(command, cwd=cwd, check=False)
              if result.returncode != 0:
                  errors.append(f"{label} failed:\n{result.stdout}")
              else:
                  print(f"ok: {label}")
      else:
          print("skip: docker not found, compose validation not run")

    return errors


def check_prometheus(config: dict[str, Any]) -> list[str]:
    if not require_tool("docker"):
        return []
    env = build(config).get(Path("observability-node/env/cloud-observability.env"))
    if not env:
        return []
    env_args: list[str] = []
    for line in env.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env_args.extend(["-e", f"{key}={value}"])
    env_args.extend(["-e", "PROMETHEUS_RENDER_ONLY=true"])
    command = [
        "docker", "run", "--rm", "--user", "0", "--entrypoint", "sh",
        "-v", f"{ROOT / 'observability-node/config/start-prometheus.sh'}:/s:ro",
        "-v", f"{ROOT / 'observability-node/config/alerts.yml'}:/etc/prometheus/alerts.yml:ro",
        *env_args,
        "prom/prometheus:latest",
        "-c", "sh /s > /tmp/prometheus.yml && promtool check config /tmp/prometheus.yml",
    ]
    result = run(command, check=False)
    if result.returncode != 0:
        return [f"prometheus generated config failed:\n{result.stdout}"]
    print("ok: prometheus generated config")
    return []


def cmd_check(args: argparse.Namespace) -> int:
    config_path, config = load_config(args.config)
    errors: list[str] = []
    try:
        if args.production:
            validate_production(config)
            print("ok: production cluster config")
        else:
            validate(config)
            print("ok: cluster config")
        build(config)
    except ConfigError as exc:
        errors.append(str(exc))

    if not errors:
        errors.extend(check_compose(config_path, config))
        errors.extend(check_prometheus(config))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("check passed")
    return 0


def format_bool(value: bool) -> str:
    return "true" if value else "false"


def cmd_add_node(args: argparse.Namespace) -> int:
    path, config = load_config(args.config)
    validate(config)
    nodes = config["nodes"]
    if any(n["name"] == args.name for n in nodes):
        raise ConfigError(f"node already exists: {args.name}")
    if any(str(n["host"]) == args.host for n in nodes):
        raise ConfigError(f"host already exists: {args.host}")

    postgres = args.postgres or not args.control
    etcd = args.etcd
    if args.no_etcd:
        etcd = False
    node_lines = [
        "",
        f"  - name: {args.name}",
        f"    host: {args.host}",
        f"    role: {'control' if args.control else 'db'}",
        f"    postgres: {format_bool(postgres)}",
        f"    etcd: {format_bool(etcd)}",
        f"    monitoring: {format_bool(args.monitoring)}",
    ]
    if postgres:
        node_lines.append(f"    local_domain: db-{args.name}.internal")
    observability = config.get("observability", {})
    loki_host = observability.get("host")
    if loki_host:
        node_lines.append(f"    loki_push_url: http://{loki_host}:3100/loki/api/v1/push")

    text = path.read_text(encoding="utf-8").rstrip() + "\n"
    if "nodes:" not in text:
        raise ConfigError("cluster config has no nodes: section")
    text += "\n".join(node_lines) + "\n"
    if args.dry_run:
        print(text)
    else:
        path.write_text(text, encoding="utf-8")
        print(f"added node {args.name} to {rel(path)}")
    return 0


def remove_node_from_text(text: str, name: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    removed = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("  - name: ") and line.split(":", 1)[1].strip() == name:
            removed = True
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.startswith("  - name: ") or (nxt and not nxt.startswith(" ")):
                    break
                i += 1
            continue
        out.append(line)
        i += 1
    if not removed:
        raise ConfigError(f"node not found: {name}")
    return "\n".join(out).rstrip() + "\n"


def cmd_remove_node(args: argparse.Namespace) -> int:
    path, config = load_config(args.config)
    validate(config)
    text = path.read_text(encoding="utf-8")
    new_text = remove_node_from_text(text, args.name)
    if args.dry_run:
        print(new_text)
    else:
        path.write_text(new_text, encoding="utf-8")
        print(f"removed node {args.name} from {rel(path)}")
    return 0


def cmd_plan(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    outputs = build(config)
    nodes = config["nodes"]
    print("Nodes:")
    for node in nodes:
        roles = []
        if node.get("postgres"):
            roles.append("postgres")
        if node.get("etcd"):
            roles.append("etcd")
        if node.get("monitoring", True):
            roles.append("monitoring")
        print(f"  {node['name']} {node['host']}: {', '.join(roles) or 'none'}")
    print("Generated files:")
    for path in sorted(outputs):
        print(f"  {path}")
    obs_env = outputs.get(Path("observability-node/env/cloud-observability.env"), "")
    lb_env = outputs.get(Path("lb-node/env/cloud-lb-a.env"), "")
    for label, text in [("DB_NODES", lb_env), ("POSTGRES_TARGETS", obs_env), ("NODE_EXPORTER_TARGETS", obs_env), ("ETCD_TARGETS", obs_env)]:
        for line in text.splitlines():
            if line.startswith(label + "="):
                print(f"{label}: {line.split('=', 1)[1]}")
    return 0


SECRET_KEY_RE = re.compile(r"(PASSWORD|SECRET|TOKEN|KEY|AUTH_PASS)", re.IGNORECASE)


def parse_env(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key] = value
    return result


def display_value(key: str, value: str, show_values: bool) -> str:
    if not show_values and SECRET_KEY_RE.search(key):
        return "<redacted>"
    return value


def cmd_diff_generated(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    outputs = build(config)
    drift = 0
    for rel_path, generated_text in sorted(outputs.items(), key=lambda item: str(item[0])):
        current_path = ROOT / rel_path
        if not current_path.exists():
            print(f"missing: {rel_path}")
            drift += 1
            continue
        current_text = current_path.read_text(encoding="utf-8")
        if current_text == generated_text:
            print(f"ok: {rel_path}")
            continue

        drift += 1
        print(f"changed: {rel_path}")
        current_env = parse_env(current_text)
        generated_env = parse_env(generated_text)
        keys = sorted(set(current_env) | set(generated_env))
        for key in keys:
            current_value = current_env.get(key)
            generated_value = generated_env.get(key)
            if current_value == generated_value:
                continue
            left = "<missing>" if current_value is None else display_value(key, current_value, args.show_values)
            right = "<missing>" if generated_value is None else display_value(key, generated_value, args.show_values)
            print(f"  {key}: current={left} generated={right}")

    if drift:
        print(f"drift detected in {drift} file(s)")
        return 1
    print("generated files match current files")
    return 0


def env_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    return parse_env(path.read_text(encoding="utf-8"))


def yaml_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    text = "" if value is None else str(value)
    if text == "" or re.search(r"[:#\[\]{},&*?\n\r\t]|^\s|\s$", text):
        return json.dumps(text)
    return text


def write_simple_yaml(data: dict[str, Any]) -> str:
    lines: list[str] = []

    def emit_map(mapping: dict[str, Any], indent: int = 0) -> None:
        prefix = " " * indent
        for key, value in mapping.items():
            if isinstance(value, dict):
                lines.append(f"{prefix}{key}:")
                emit_map(value, indent + 2)
            elif isinstance(value, list):
                lines.append(f"{prefix}{key}:")
                for item in value:
                    if isinstance(item, dict):
                        first = True
                        for item_key, item_value in item.items():
                            if first:
                                if isinstance(item_value, dict):
                                    lines.append(f"{prefix}  - {item_key}:")
                                    emit_map(item_value, indent + 6)
                                else:
                                    lines.append(f"{prefix}  - {item_key}: {yaml_scalar(item_value)}")
                                first = False
                            elif isinstance(item_value, dict):
                                lines.append(f"{prefix}    {item_key}:")
                                emit_map(item_value, indent + 6)
                            else:
                                lines.append(f"{prefix}    {item_key}: {yaml_scalar(item_value)}")
                    else:
                        lines.append(f"{prefix}  - {yaml_scalar(item)}")
            else:
                lines.append(f"{prefix}{key}: {yaml_scalar(value)}")

    emit_map(data)
    return "\n".join(lines) + "\n"


def parse_etcd_initial_cluster(value: str) -> list[tuple[str, str]]:
    peers: list[tuple[str, str]] = []
    for item in value.split(","):
        if "=" not in item:
            continue
        name, url = item.split("=", 1)
        host = url.removeprefix("http://").split(":", 1)[0]
        if name and host:
            peers.append((name, host))
    return peers


def add_if_present(target: dict[str, Any], key: str, value: str | None) -> None:
    if value:
        target[key] = value


def cmd_adopt_env(args: argparse.Namespace) -> int:
    cluster_out = Path(args.cluster_out)
    secrets_out = Path(args.secrets_out)
    if not args.force:
        for path in [cluster_out, secrets_out]:
            if path.exists():
                raise ConfigError(f"{path} already exists; use --force to overwrite")

    db_envs = sorted((ROOT / "db-node" / "env").glob("*.env"))
    if not db_envs:
        raise ConfigError("no db-node/env/*.env files found")

    db_data = [(path.stem, env_file(path)) for path in db_envs]
    first_db_name, first_db = next((name, env) for name, env in db_data if env.get("INTERNAL_BIND_IP"))
    lb_env = env_file(ROOT / "lb-node" / "env" / "cloud-lb-a.env")
    obs_env = env_file(ROOT / "observability-node" / "env" / "cloud-observability.env")

    peers = parse_etcd_initial_cluster(first_db.get("ETCD_INITIAL_CLUSTER", ""))
    peer_by_host = {host: name for name, host in peers}
    db_hosts = {env.get("INTERNAL_BIND_IP"): name for name, env in db_data if env.get("INTERNAL_BIND_IP")}

    nodes: list[dict[str, Any]] = []
    control_host = obs_env.get("CLOUD_CONTROL_HOST") or lb_env.get("INTERNAL_BIND_IP")
    if control_host:
        control_etcd_name = peer_by_host.get(control_host, "etcd-cloud")
        nodes.append({
            "name": "cloud-control",
            "host": control_host,
            "role": "control",
            "etcd_name": control_etcd_name,
            "etcd": control_host in peer_by_host,
            "postgres": False,
            "monitoring": True,
            "node_exporter_port": int(obs_env.get("CLOUD_CONTROL_NODE_EXPORTER_PORT") or 9100),
            "loki_push_url": first_db.get("LOKI_PUSH_URL") or "",
        })

    known_node_names = {node["name"] for node in nodes}
    for name, env in db_data:
        host = env.get("INTERNAL_BIND_IP")
        if not host:
            continue
        etcd_name = peer_by_host.get(host) or env.get("ETCD_NAME") or f"etcd-{name}"
        node = {
            "name": name,
            "host": host,
            "role": "db",
            "postgres": True,
            "etcd": host in peer_by_host,
            "monitoring": True,
            "local_domain": env.get("LOCAL_DB_DOMAIN", f"db-{name}.internal"),
            "loki_push_url": env.get("LOKI_PUSH_URL", first_db.get("LOKI_PUSH_URL", "")),
        }
        add_if_present(node, "db_ip", env.get("DB_IP"))
        add_if_present(node, "etcd_ip", env.get("ETCD_IP"))
        add_if_present(node, "local_lb_ip", env.get("LOCAL_LB_IP"))
        add_if_present(node, "postgres_exporter_ip", env.get("POSTGRES_EXPORTER_IP"))
        add_if_present(node, "node_exporter_ip", env.get("NODE_EXPORTER_IP"))
        add_if_present(node, "promtail_ip", env.get("PROMTAIL_IP"))
        if host in peer_by_host:
            node["etcd_name"] = etcd_name
        known_node_names.add(name)
        nodes.append(node)

    lb_db_items = lb_env.get("DB_NODES", "")
    if not lb_db_items:
        legacy = []
        for suffix, node_name in [("A", "city-a"), ("B", "city-b"), ("C", "city-c")]:
            host = lb_env.get(f"DB_HOST_{suffix}")
            if host:
                legacy.append(f"{node_name}={host}")
        lb_db_items = " ".join(legacy)
    for item in lb_db_items.replace(",", " ").split():
        if "=" in item:
            name, host = item.split("=", 1)
        else:
            host = item
            name = item.split(":", 1)[0]
        if name in known_node_names:
            continue
        node = {
            "name": name,
            "host": host,
            "role": "db",
            "postgres": True,
            "etcd": host in peer_by_host,
            "monitoring": True,
            "local_domain": f"db-{name}.internal",
            "loki_push_url": first_db.get("LOKI_PUSH_URL", ""),
        }
        if host in peer_by_host:
            node["etcd_name"] = peer_by_host[host]
        known_node_names.add(name)
        nodes.append(node)

    control_nodes = [node for node in nodes if node.get("role") == "control"]
    db_nodes_adopted = sorted((node for node in nodes if node.get("role") == "db"), key=lambda item: str(item["name"]))
    nodes = control_nodes + db_nodes_adopted

    config = {
        "cluster": {
            "name": "belka",
            "patroni_scope": first_db.get("PATRONI_SCOPE", "belka-ha"),
            "preferred_primary": first_db_name,
            "docker_network": first_db.get("BELKA_NETWORK_NAME", "belkasql_belka-net"),
            "docker_subnet": "172.28.0.0/16",
        },
        "ports": {
            "postgres": 5432,
            "patroni_api": int(first_db.get("PATRONI_API_PUBLISHED_PORT") or 8008),
            "pgbouncer": int(first_db.get("PGBOUNCER_PUBLISHED_PORT") or 6432),
            "postgres_exporter": int(first_db.get("POSTGRES_EXPORTER_PUBLISHED_PORT") or 9187),
            "node_exporter": int(first_db.get("NODE_EXPORTER_PUBLISHED_PORT") or 9100),
            "local_write": int(first_db.get("LOCAL_LB_WRITE_PUBLISHED_PORT") or 5000),
            "local_read": int(first_db.get("LOCAL_LB_READ_PUBLISHED_PORT") or 5001),
        },
        "etcd": {
            "heartbeat_interval": int(first_db.get("ETCD_HEARTBEAT_INTERVAL") or 2000),
            "election_timeout": int(first_db.get("ETCD_ELECTION_TIMEOUT") or 10000),
            "client_port": int(first_db.get("ETCD_CLIENT_PUBLISHED_PORT") or 2379),
            "peer_port": 2380,
        },
        "backup": {
            "stanza": first_db.get("BACKREST_STANZA", "belka"),
            "bucket": first_db.get("BACKREST_S3_BUCKET", ""),
            "endpoint": first_db.get("BACKREST_S3_ENDPOINT", ""),
            "region": first_db.get("BACKREST_S3_REGION", "us-east-1"),
            "port": int(first_db.get("BACKREST_S3_PORT") or 9000),
            "verify_tls": first_db.get("BACKREST_S3_VERIFY_TLS", "n").lower() in {"y", "yes", "true", "1"},
        },
        "observability": {
            "enabled": bool(obs_env),
            "host": obs_env.get("INTERNAL_BIND_IP") or control_host or "",
            "internal_bind_ip": obs_env.get("INTERNAL_BIND_IP") or control_host or "",
            "grafana_port": int(obs_env.get("GRAFANA_PUBLISHED_PORT") or 3000),
            "prometheus_port": int(obs_env.get("PROMETHEUS_PUBLISHED_PORT") or 9090),
            "loki_port": int(obs_env.get("LOKI_PUBLISHED_PORT") or 3100),
            "alertmanager_port": int(obs_env.get("ALERTMANAGER_PUBLISHED_PORT") or 9093),
            "grafana_root_url": obs_env.get("GRAFANA_ROOT_URL", ""),
            "grafana_admin_user": obs_env.get("GRAFANA_ADMIN_USER", "admin"),
            "backup_metrics_targets": obs_env.get("BACKUP_METRICS_TARGETS", ""),
        },
        "load_balancer": {
            "enabled": bool(lb_env),
            "host": lb_env.get("INTERNAL_BIND_IP") or control_host or "",
            "internal_bind_ip": lb_env.get("INTERNAL_BIND_IP") or control_host or "",
            "keepalived_enabled": truthy(lb_env.get("KEEPALIVED_ENABLED"), True),
            "write_domain": lb_env.get("DB_WRITE_DOMAIN", "db-write.internal"),
            "read_domain": lb_env.get("DB_READ_DOMAIN", "db-read.internal"),
            "write_port": int(lb_env.get("LB_WRITE_PUBLISHED_PORT") or 5000),
            "read_port": int(lb_env.get("LB_READ_PUBLISHED_PORT") or 5001),
            "metrics_port": int(lb_env.get("LB_METRICS_PUBLISHED_PORT") or 8404),
        },
        "nodes": nodes,
    }

    secrets = {
        "etcd": {"token": first_db.get("ETCD_CLUSTER_TOKEN", "")},
        "backup": {
            "key": first_db.get("BACKREST_S3_KEY", ""),
            "secret": first_db.get("BACKREST_S3_SECRET", ""),
        },
        "postgres": {
            "superuser_password": first_db.get("POSTGRES_SUPERUSER_PASSWORD", ""),
            "replication_password": first_db.get("REPLICATION_PASSWORD", ""),
            "app_user_password": first_db.get("APP_USER_PASSWORD", ""),
        },
        "observability": {
            "grafana_admin_password": obs_env.get("GRAFANA_ADMIN_PASSWORD", ""),
        },
        "load_balancer": {
            "keepalived_auth_pass": lb_env.get("KEEPALIVED_AUTH_PASS", ""),
        },
    }

    if args.dry_run:
        print(f"--- {cluster_out} ---")
        print(write_simple_yaml(config), end="")
        print(f"--- {secrets_out} ---")
        print("# secret values are detected but not printed in dry-run")
        return 0

    cluster_out.write_text(write_simple_yaml(config), encoding="utf-8")
    secrets_out.write_text(write_simple_yaml(secrets), encoding="utf-8")
    print(f"wrote {cluster_out}")
    print(f"wrote {secrets_out}")
    print("next: ./belkasql diff-generated cluster.yml && ./belkasql check cluster.yml --production")
    return 0


def http_json(url: str, timeout: int = 5) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def prom_query(base_url: str, query: str) -> Any:
    url = base_url.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
    return http_json(url)


def cmd_status(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    validate(config)
    nodes = config["nodes"]
    db_nodes = [n for n in nodes if n.get("postgres") is True]
    obs = config.get("observability", {})
    prom = f"http://{obs.get('host', '127.0.0.1')}:{obs.get('prometheus_port', 9090)}"

    print("Patroni:")
    cluster = None
    for node in db_nodes:
        try:
            cluster = http_json(f"http://{node['host']}:8008/cluster", timeout=4)
            break
        except Exception:
            continue
    if not cluster:
        print("  unavailable")
    else:
        for member in cluster.get("members", []):
            lag = member.get("lag", 0)
            print(f"  {member.get('name')}: {member.get('role')} / {member.get('state')} / lag={lag}")

    print("Prometheus:")
    for label, query in [
        ("postgres up", "sum(pg_up)"),
        ("postgres total", "count(pg_up)"),
        ("primary count", "sum(1 - pg_replication_is_replica)"),
        ("max replication lag", "max(pg_stat_replication_pg_wal_lsn_diff or vector(0))"),
        ("backup age seconds", "max(belka_pgbackrest_latest_backup_age_seconds)"),
    ]:
        try:
            result = prom_query(prom, query)["data"]["result"]
            value = result[0]["value"][1] if result else "n/a"
            print(f"  {label}: {value}")
        except Exception as exc:
            print(f"  {label}: unavailable ({exc})")
    return 0


def tcp_check(host: str, port: int, timeout: float = 2.0) -> tuple[bool, str]:
    import socket

    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, "ok"
    except Exception as exc:
        return False, str(exc)


def cmd_doctor(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    validate(config)
    errors = 0
    print("Network/services:")
    for node in config["nodes"]:
        host = str(node["host"])
        checks: list[tuple[str, int]] = []
        if node.get("postgres"):
            checks.extend([("patroni", 8008), ("postgres", 5432), ("pgbouncer", 6432), ("postgres-exporter", 9187)])
        if node.get("etcd"):
            checks.append(("etcd", 2379))
        if node.get("monitoring", True):
            checks.append(("node-exporter", int(node.get("node_exporter_port", config.get("ports", {}).get("node_exporter", 9100)))))
        for label, port in checks:
            ok, detail = tcp_check(host, port)
            status = "ok" if ok else "fail"
            errors += 0 if ok else 1
            print(f"  {node['name']} {label} {host}:{port}: {status}" + ("" if ok else f" ({detail})"))

    print("Cluster summary:")
    cmd_status(args)
    return 1 if errors else 0


def target_nodes(config: dict[str, Any], target: str) -> list[dict[str, Any]]:
    if target == "all":
        nodes = list(config["nodes"])
        if truthy(config.get("load_balancer", {}).get("enabled")):
            nodes.extend(target_nodes(config, "lb"))
        if truthy(config.get("observability", {}).get("enabled")):
            nodes.extend(target_nodes(config, "observability"))
        return nodes
    if target in {"lb", "load-balancer"}:
        lb = config.get("load_balancer", {})
        return [{"name": "cloud-lb-a", "host": lb.get("host"), "apply_role": "lb"}]
    if target in {"observability", "monitoring"}:
        obs = config.get("observability", {})
        return [{"name": "cloud-observability", "host": obs.get("host"), "apply_role": "observability"}]
    for node in config["nodes"]:
        if node["name"] == target:
            return [node]
    raise ConfigError(f"unknown apply target: {target}")


def node_os(node: dict[str, Any], default: str = "linux") -> str:
    return str(node.get("os") or node.get("platform") or default).strip().lower()


def node_repo_dir(node: dict[str, Any], default_repo_dir: str) -> str:
    return str(node.get("repo_dir") or default_repo_dir)


def node_ssh_user(node: dict[str, Any], default_user: str) -> str:
    return str(node.get("ssh_user") or default_user)


def node_ssh_port(node: dict[str, Any], config: dict[str, Any]) -> int:
    ssh = config.get("ssh", {})
    return int(node.get("ssh_port") or ssh.get("port") or 22)


def node_ssh_password(node: dict[str, Any], config: dict[str, Any]) -> str:
    ssh = config.get("ssh", {})
    passwords = ssh.get("passwords", {})
    if isinstance(passwords, dict):
        value = passwords.get(node.get("name"))
        if value:
            return str(value)
    return str(node.get("ssh_password") or ssh.get("password") or "")


def node_ssh_identity_file(node: dict[str, Any], config: dict[str, Any]) -> str:
    ssh = config.get("ssh", {})
    value = node.get("ssh_identity_file") or ssh.get("identity_file") or ""
    if not value:
        return ""
    expanded = os.path.expandvars(os.path.expanduser(str(value)))
    path = Path(expanded)
    if not path.is_absolute():
        path = Path.cwd() / path
    return str(path)


def ssh_args(port: int, identity_file: str = "") -> list[str]:
    args = ["ssh"]
    if identity_file:
        args.extend(["-i", identity_file, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"])
    if port != 22:
        args.extend(["-p", str(port)])
    return args


def scp_args(port: int, identity_file: str = "") -> list[str]:
    args = ["scp"]
    if identity_file:
        args.extend(["-i", identity_file, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"])
    if port != 22:
        args.extend(["-P", str(port)])
    return args


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def ensure_network_command(config: dict[str, Any]) -> str:
    network = shlex.quote(str(config.get("cluster", {}).get("docker_network", "belkasql_belka-net")))
    subnet = shlex.quote(str(config.get("cluster", {}).get("docker_subnet", "172.28.0.0/16")))
    return f"(docker network inspect {network} >/dev/null 2>&1 || docker network create --subnet {subnet} {network})"


def ensure_network_powershell(config: dict[str, Any]) -> str:
    network = ps_quote(str(config.get("cluster", {}).get("docker_network", "belkasql_belka-net")))
    subnet = ps_quote(str(config.get("cluster", {}).get("docker_subnet", "172.28.0.0/16")))
    return f"docker network inspect {network} *> $null; if ($LASTEXITCODE -ne 0) {{ docker network create --subnet {subnet} {network} | Out-Null }}"


def powershell_command(script: str) -> str:
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    return f"powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}"


def remote_role_command_linux(node: dict[str, Any], repo_dir: str, config: dict[str, Any]) -> str:
    role = node.get("apply_role") or node.get("role")
    name = node["name"]
    repo = shlex.quote(repo_dir)
    ensure_network = ensure_network_command(config)
    if role == "lb":
        return f"cd {repo} && {ensure_network} && docker compose --env-file lb-node/env/cloud-lb-a.env -f lb-node/docker-compose.yml config -q && docker compose --env-file lb-node/env/cloud-lb-a.env -f lb-node/docker-compose.yml up -d --build"
    if role == "observability":
        return f"cd {repo} && {ensure_network} && docker compose --env-file observability-node/env/cloud-observability.env -f observability-node/docker-compose.yml config -q && docker compose --env-file observability-node/env/cloud-observability.env -f observability-node/docker-compose.yml up -d --build"
    if node.get("postgres"):
        compose = "docker-compose.yml" if node.get("etcd") else "docker-compose.replica.yml"
        env_name = shlex.quote(f"env/{name}.env")
        return f"cd {repo}/db-node && {ensure_network} && docker compose --env-file {env_name} -f {compose} config -q && docker compose --env-file {env_name} -f {compose} up -d --build"
    if node.get("etcd"):
        env_name = shlex.quote(f"control-node/env/{name}.env")
        return f"cd {repo} && {ensure_network} && docker compose --env-file {env_name} -f control-node/docker-compose.yml config -q && docker compose --env-file {env_name} -f control-node/docker-compose.yml up -d --build"
    raise ConfigError(f"do not know how to apply node: {name}")


def remote_role_command_windows(node: dict[str, Any], repo_dir: str, config: dict[str, Any]) -> str:
    role = node.get("apply_role") or node.get("role")
    name = str(node["name"])
    repo = repo_dir.rstrip("\\/")
    ensure_network = ensure_network_powershell(config)
    if role == "lb":
        workdir = repo
        env_file = "lb-node/env/cloud-lb-a.env"
        compose = "lb-node/docker-compose.yml"
    elif role == "observability":
        workdir = repo
        env_file = "observability-node/env/cloud-observability.env"
        compose = "observability-node/docker-compose.yml"
    elif node.get("postgres"):
        workdir = repo + "\\db-node"
        env_file = f"env/{name}.env"
        compose = "docker-compose.yml" if node.get("etcd") else "docker-compose.replica.yml"
    elif node.get("etcd"):
        workdir = repo
        env_file = f"control-node/env/{name}.env"
        compose = "control-node/docker-compose.yml"
    else:
        raise ConfigError(f"do not know how to apply node: {name}")

    script = (
        "$ErrorActionPreference='Stop'; "
        f"Set-Location {ps_quote(workdir)}; "
        f"{ensure_network}; "
        f"docker compose --env-file {ps_quote(env_file)} -f {ps_quote(compose)} config -q; "
        f"docker compose --env-file {ps_quote(env_file)} -f {ps_quote(compose)} up -d --build"
    )
    return powershell_command(script)


def remote_role_command(node: dict[str, Any], repo_dir: str, config: dict[str, Any]) -> str:
    os_name = node_os(node)
    if os_name == "windows":
        return remote_role_command_windows(node, repo_dir, config)
    if os_name == "linux":
        return remote_role_command_linux(node, repo_dir, config)
    raise ConfigError(f"unsupported target os for {node.get('name')}: {os_name}")


def remote_prepare_command(node: dict[str, Any], repo_dir: str) -> str:
    if node_os(node) == "windows":
        script = f"$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Force -Path {ps_quote(repo_dir)} | Out-Null"
        return powershell_command(script)
    return f"mkdir -p {shlex.quote(repo_dir)}"


def remote_extract_command(node: dict[str, Any], remote_archive: str, repo_dir: str) -> str:
    if node_os(node) == "windows":
        script = (
            "$ErrorActionPreference='Stop'; "
            f"New-Item -ItemType Directory -Force -Path {ps_quote(repo_dir)} | Out-Null; "
            f"tar -xzf {ps_quote(remote_archive)} -C {ps_quote(repo_dir)}; "
            f"Remove-Item -Force {ps_quote(remote_archive)}"
        )
        return powershell_command(script)
    return f"tar -xzf {shlex.quote(remote_archive)} -C {shlex.quote(repo_dir)} && rm -f {shlex.quote(remote_archive)}"


def remote_archive_path(node: dict[str, Any], archive: Path) -> str:
    if node_os(node) == "windows":
        return f"C:/Windows/Temp/{archive.name}"
    return f"/tmp/{archive.name}"


def run_native_ssh(user_host: str, command: str) -> None:
    run(["ssh", user_host, command])


def upload_native_scp(local_path: Path, user_host: str, remote_path: str) -> None:
    run(["scp", str(local_path), f"{user_host}:{remote_path}"])


def run_paramiko_sequence(host: str, port: int, user: str, password: str, archive: Path, remote_archive: str, repo_dir: str, node: dict[str, Any], command: str) -> None:
    try:
        import paramiko
    except ImportError as exc:
        raise ConfigError("password SSH transport requires Python package 'paramiko'") from exc

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=host,
            port=port,
            username=user,
            password=password,
            timeout=20,
            banner_timeout=20,
            auth_timeout=20,
            look_for_keys=False,
            allow_agent=False,
        )
        for step in [remote_prepare_command(node, repo_dir)]:
            exec_paramiko(client, step)
        with client.open_sftp() as sftp:
            sftp.put(str(archive), remote_archive)
        for step in [remote_extract_command(node, remote_archive, repo_dir), command]:
            exec_paramiko(client, step)
    finally:
        client.close()


def run_paramiko_command(host: str, port: int, user: str, password: str, command: str) -> None:
    try:
        import paramiko
    except ImportError as exc:
        raise ConfigError("password SSH transport requires Python package 'paramiko'") from exc

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=host,
            port=port,
            username=user,
            password=password,
            timeout=20,
            banner_timeout=20,
            auth_timeout=20,
            look_for_keys=False,
            allow_agent=False,
        )
        exec_paramiko(client, command)
    finally:
        client.close()


def exec_paramiko(client: Any, command: str) -> None:
    stdin, stdout, stderr = client.exec_command(command, timeout=600)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    if err.startswith("#< CLIXML"):
        err = ""
    rc = stdout.channel.recv_exit_status()
    if out:
        print(out, end="")
    if err:
        print(err, end="", file=sys.stderr)
    if rc != 0:
        raise ConfigError(f"remote command failed with exit code {rc}: {command}")


def create_repo_archive(generated: Path) -> Path:
    fd, archive_name = tempfile.mkstemp(prefix="belkasql-apply-", suffix=".tar.gz")
    os.close(fd)
    archive = Path(archive_name)
    staging = Path(tempfile.mkdtemp(prefix="belkasql-apply-stage-"))
    root_files = ["README.md", ".gitattributes", "belkasql", "belkasql.ps1"]
    root_dirs = ["scripts", "db-node", "control-node", "lb-node", "observability-node", "storage-node", "docs"]

    def ignore_local(dir_path: str, names: list[str]) -> set[str]:
        ignored = {".git", ".generated", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"}
        ignored.update(name for name in names if name == "env")
        ignored.update(name for name in names if name.endswith((".env", ".log", ".tmp", ".bak", ".orig")))
        ignored.update(name for name in names if ".bak-" in name)
        if Path(dir_path) == ROOT:
            ignored.update({"cluster.yml", "secrets.yml", "cluster.lock", "keys", "steps", "test"})
        return ignored

    try:
        for file_name in root_files:
            src = ROOT / file_name
            if src.exists():
                shutil.copy2(src, staging / file_name)
        for dir_name in root_dirs:
            src = ROOT / dir_name
            if src.exists():
                shutil.copytree(src, staging / dir_name, ignore=ignore_local)
        for path in generated.rglob("*"):
            if path.is_dir():
                continue
            rel_path = path.relative_to(generated)
            target = staging / rel_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        with tarfile.open(archive, "w:gz") as tar:
            for path in staging.rglob("*"):
                rel_path = path.relative_to(staging)
                tar.add(path, arcname=str(rel_path))
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return archive


def cmd_apply(args: argparse.Namespace) -> int:
    config_path, config = load_config(args.config)
    if not args.allow_non_production:
        try:
            validate_production(config)
        except ConfigError as exc:
            if args.dry_run:
                print(f"warning: production validation failed: {exc}", file=sys.stderr)
                print("warning: dry-run continues; real apply would be blocked without --allow-non-production", file=sys.stderr)
            else:
                raise ConfigError(f"apply blocked by production validation: {exc}. Use --allow-non-production only for lab/test deploys.")
    outputs = build(config)
    generated = ROOT / ".generated"
    if generated.exists():
        shutil.rmtree(generated)
    write_outputs(outputs, generated, dry_run=False)
    write_lock(config_path, outputs, generated)

    archive = create_repo_archive(generated)
    try:
        nodes = target_nodes(config, args.target)
        for node in nodes:
            host = node.get("host")
            if not host:
                raise ConfigError(f"target has no host: {node.get('name')}")
            ssh_user = node_ssh_user(node, args.user)
            ssh_port = node_ssh_port(node, config)
            identity_file = node_ssh_identity_file(node, config)
            ssh_password = "" if identity_file else node_ssh_password(node, config)
            user_host = f"{ssh_user}@{host}" if ssh_user else str(host)
            repo_dir = node_repo_dir(node, args.repo_dir)
            command = remote_role_command(node, repo_dir, config)
            print(f"target {node.get('name')} ({host})")
            print(f"  os: {node_os(node)}")
            transport = f"key {identity_file}" if identity_file else ("password" if ssh_password else "ssh/scp")
            print(f"  ssh: {ssh_user}@{host}:{ssh_port} ({transport})")
            print(f"  sync: {archive} -> {user_host}:{repo_dir}")
            print(f"  run: {command}")
            if args.dry_run:
                continue
            remote_archive = remote_archive_path(node, archive)
            if ssh_password:
                run_paramiko_sequence(str(host), ssh_port, ssh_user, ssh_password, archive, remote_archive, repo_dir, node, command)
            else:
                if not require_tool("scp") or not require_tool("ssh"):
                    raise ConfigError("apply requires ssh and scp in PATH when no ssh_password is configured")
                ssh_target = f"{ssh_user}@{host}" if ssh_user else str(host)
                run([*ssh_args(ssh_port, identity_file), ssh_target, remote_prepare_command(node, repo_dir)])
                run([*scp_args(ssh_port, identity_file), str(archive), f"{ssh_target}:{remote_archive}"])
                run([*ssh_args(ssh_port, identity_file), ssh_target, remote_extract_command(node, remote_archive, repo_dir)])
                run([*ssh_args(ssh_port, identity_file), ssh_target, command])
    finally:
        archive.unlink(missing_ok=True)
    return 0


def remote_preflight_command(node: dict[str, Any], repo_dir: str, config: dict[str, Any]) -> str:
    if node_os(node) == "windows":
        script = (
            "$ErrorActionPreference='Stop'; "
            "hostname; "
            "docker --version; "
            "docker compose version; "
            f"New-Item -ItemType Directory -Force -Path {ps_quote(repo_dir)} | Out-Null; "
            f"{ensure_network_powershell(config)}; "
            "docker network inspect " + ps_quote(str(config.get("cluster", {}).get("docker_network", "belkasql_belka-net"))) + " | Out-Null"
        )
        return powershell_command(script)
    return (
        "set -e; "
        "hostname; "
        "docker --version; "
        "docker compose version; "
        f"mkdir -p {shlex.quote(repo_dir)}; "
        f"{ensure_network_command(config)}; "
        f"docker network inspect {shlex.quote(str(config.get('cluster', {}).get('docker_network', 'belkasql_belka-net')))} >/dev/null"
    )


def cmd_preflight_remote(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    validate(config)
    failures = 0
    for node in target_nodes(config, args.target):
        host = node.get("host")
        if not host:
            print(f"fail: {node.get('name')} has no host")
            failures += 1
            continue
        ssh_user = node_ssh_user(node, args.user)
        ssh_port = node_ssh_port(node, config)
        identity_file = node_ssh_identity_file(node, config)
        ssh_password = "" if identity_file else node_ssh_password(node, config)
        repo_dir = node_repo_dir(node, args.repo_dir)
        command = remote_preflight_command(node, repo_dir, config)
        transport = f"key {identity_file}" if identity_file else ("password" if ssh_password else "ssh/scp")
        print(f"target {node.get('name')} ({node_os(node)}) {ssh_user}@{host}:{ssh_port} ({transport})")
        if args.dry_run:
            print(f"  run: {command}")
            continue
        try:
            if ssh_password:
                run_paramiko_command(str(host), ssh_port, ssh_user, ssh_password, command)
            else:
                ssh_target = f"{ssh_user}@{host}" if ssh_user else str(host)
                result = run([*ssh_args(ssh_port, identity_file), ssh_target, command], check=False)
                print(result.stdout, end="")
                if result.returncode != 0:
                    raise ConfigError(f"remote preflight failed with exit code {result.returncode}")
            print(f"ok: {node.get('name')}")
        except Exception as exc:
            failures += 1
            print(f"fail: {node.get('name')}: {exc}", file=sys.stderr)
    return 1 if failures else 0


def ensure_ssh_key(path_arg: str, dry_run: bool) -> Path:
    key_path = Path(os.path.expandvars(os.path.expanduser(path_arg)))
    if not key_path.is_absolute():
        key_path = Path.cwd() / key_path
    if key_path.exists():
        return key_path
    print(f"create SSH key: {key_path}")
    if dry_run:
        return key_path
    key_path.parent.mkdir(parents=True, exist_ok=True)
    run(["ssh-keygen", "-t", "ed25519", "-f", str(key_path), "-N", "", "-C", "belkasql-deploy"])
    return key_path


def install_public_key_command(node: dict[str, Any], public_key: str) -> str:
    if node_os(node) == "windows":
        script = (
            "$ErrorActionPreference='Stop'; "
            f"$key = {ps_quote(public_key)}; "
            "$path = 'C:\\ProgramData\\ssh\\administrators_authorized_keys'; "
            "New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null; "
            "if (!(Test-Path $path)) { New-Item -ItemType File -Force -Path $path | Out-Null }; "
            "$content = Get-Content -Raw -ErrorAction SilentlyContinue $path; "
            "if ($content -notlike ('*' + $key + '*')) { Add-Content -Path $path -Value $key }; "
            "icacls $path /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null; "
            "Restart-Service sshd -ErrorAction SilentlyContinue"
        )
        return powershell_command(script)
    key = shlex.quote(public_key)
    return (
        "set -e; "
        "mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; "
        f"grep -qxF {key} ~/.ssh/authorized_keys || printf '%s\\n' {key} >> ~/.ssh/authorized_keys; "
        "chmod 600 ~/.ssh/authorized_keys"
    )


def cmd_bootstrap_ssh_keys(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    key_path = ensure_ssh_key(args.key_path, args.dry_run)
    public_path = Path(str(key_path) + ".pub")
    if args.dry_run and not public_path.exists():
        public_key = "ssh-ed25519 DRY-RUN belkasql-deploy"
    else:
        if not public_path.exists():
            raise ConfigError(f"public key not found: {public_path}")
        public_key = public_path.read_text(encoding="utf-8").strip()
    failures = 0
    for node in target_nodes(config, args.target):
        host = node.get("host")
        if not host:
            print(f"fail: {node.get('name')} has no host")
            failures += 1
            continue
        ssh_user = node_ssh_user(node, args.user)
        ssh_port = node_ssh_port(node, config)
        password = node_ssh_password(node, config)
        command = install_public_key_command(node, public_key)
        print(f"target {node.get('name')} ({node_os(node)}) {ssh_user}@{host}:{ssh_port}")
        if args.dry_run:
            print(f"  run: {command}")
            continue
        if not password:
            print(f"fail: {node.get('name')}: password is required for one-time key bootstrap", file=sys.stderr)
            failures += 1
            continue
        try:
            run_paramiko_command(str(host), ssh_port, ssh_user, password, command)
            print(f"ok: {node.get('name')}")
        except Exception as exc:
            failures += 1
            print(f"fail: {node.get('name')}: {exc}", file=sys.stderr)
    return 1 if failures else 0


def ssh_target_for_control(config: dict[str, Any], user: str) -> str:
    obs = config.get("observability", {})
    host = obs.get("host") or config.get("load_balancer", {}).get("host")
    if not host:
        for node in config["nodes"]:
            if node.get("role") == "control":
                host = node.get("host")
                break
    if not host:
        raise ConfigError("cannot find control/observability host")
    return f"{user}@{host}" if user else str(host)


def ssh_target_for_node(node: dict[str, Any], user: str) -> str:
    host = node.get("host")
    if not host:
        raise ConfigError(f"node has no host: {node.get('name')}")
    return f"{user}@{host}" if user else str(host)


def run_remote(user_host: str, command: str, dry_run: bool) -> int:
    print(f"ssh {user_host} {command}")
    if dry_run:
        return 0
    result = run(["ssh", user_host, command], check=False)
    print(result.stdout, end="")
    return result.returncode


def generated_env_for_node(config: dict[str, Any], node: dict[str, Any]) -> dict[str, str]:
    project = str(node["name"])
    env_path = Path("db-node") / "env" / f"{project}.env"
    outputs = build(config)
    content = outputs.get(env_path)
    if content is None:
        raise ConfigError(f"no generated DB env for node: {node['name']}")
    return parse_env(content)


def patroni_role(node: dict[str, Any]) -> str | None:
    host = node.get("host")
    if not host:
        return None
    for role, endpoint in [("primary", "primary"), ("replica", "replica")]:
        try:
            with urllib.request.urlopen(f"http://{host}:8008/{endpoint}", timeout=3) as response:
                if response.status == 200:
                    return role
        except Exception:
            continue
    return None


def choose_db_node(config: dict[str, Any], preference: str) -> tuple[dict[str, Any], str]:
    db_nodes = [n for n in config["nodes"] if truthy(n.get("postgres"))]
    if not db_nodes:
        raise ConfigError("no postgres nodes in config")

    roles: list[tuple[dict[str, Any], str | None]] = [(node, patroni_role(node)) for node in db_nodes]
    if preference == "primary":
        for node, role in roles:
            if role == "primary":
                return node, role
    if preference == "replica":
        for node, role in roles:
            if role == "replica":
                return node, role
        raise ConfigError("no reachable replica found")
    if preference == "auto":
        for node, role in roles:
            if role == "replica":
                return node, role
        for node, role in roles:
            if role == "primary":
                return node, role

    preferred = config.get("cluster", {}).get("preferred_primary")
    fallback = next((n for n in db_nodes if n.get("name") == preferred), db_nodes[0])
    return fallback, "unknown"


def pgbackrest_remote_command(action: str, stanza: str, container: str) -> str:
    quoted_container = shlex.quote(container)
    quoted_stanza = shlex.quote(stanza)
    if action == "status":
        inner = f"pgbackrest --stanza={quoted_stanza} info"
    else:
        inner = f"pgbackrest --stanza={quoted_stanza} --type={shlex.quote(action)} backup && pgbackrest --stanza={quoted_stanza} info"
    return f"docker exec {quoted_container} bash -lc {shlex.quote(inner)}"


def cmd_backup(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    validate(config)
    node, role = choose_db_node(config, args.from_node)
    env = generated_env_for_node(config, node)
    user_host = ssh_target_for_node(node, args.user)
    stanza = env.get("BACKREST_STANZA", config.get("backup", {}).get("stanza", "belka"))
    container = env.get("DB_CONTAINER_NAME")
    if not container:
        raise ConfigError(f"generated env has no DB_CONTAINER_NAME for {node['name']}")
    command = pgbackrest_remote_command(args.action, str(stanza), container)
    print(f"backup target: {node['name']} ({role})")
    return run_remote(user_host, command, args.dry_run)


def cmd_restore_test(args: argparse.Namespace) -> int:
    _, config = load_config(args.config)
    validate(config)
    node, role = choose_db_node(config, args.from_node)
    env = generated_env_for_node(config, node)
    user_host = ssh_target_for_node(node, args.user)
    stanza = shlex.quote(env.get("BACKREST_STANZA", config.get("backup", {}).get("stanza", "belka")))
    container = shlex.quote(env.get("DB_CONTAINER_NAME", ""))
    if container == "''":
        raise ConfigError(f"generated env has no DB_CONTAINER_NAME for {node['name']}")
    inner = (
        "set -euo pipefail; "
        "TMP=/tmp/belkasql-restore-test-$(date +%Y%m%d%H%M%S); "
        "rm -rf \"$TMP\"; mkdir -p \"$TMP\"; "
        f"pgbackrest --stanza={stanza} --pg1-path=\"$TMP\" restore; "
        "find \"$TMP\" -maxdepth 2 | head -40; "
        "rm -rf \"$TMP\""
    )
    command = f"docker exec {container} bash -lc {shlex.quote(inner)}"
    print(f"restore-test target: {node['name']} ({role})")
    if not args.run:
        print("Dry run. Use --run to execute the remote scratch restore.")
        print(f"ssh {user_host} {command}")
        return 0
    return run_remote(user_host, command, dry_run=False)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="belkasql")
    sub = p.add_subparsers(dest="command", required=True)

    g = sub.add_parser("generate")
    g.add_argument("config", nargs="?", default="cluster.yml")
    g.add_argument("--out", default=str(ROOT))
    g.add_argument("--dry-run", action="store_true")
    g.set_defaults(func=cmd_generate)

    c = sub.add_parser("check")
    c.add_argument("config", nargs="?", default="cluster.yml")
    c.add_argument("--production", action="store_true", help="fail on placeholder/example production values")
    c.set_defaults(func=cmd_check)

    a = sub.add_parser("add-node")
    a.add_argument("name")
    a.add_argument("host")
    a.add_argument("--config", default="cluster.yml")
    a.add_argument("--postgres", action="store_true")
    a.add_argument("--control", action="store_true")
    a.add_argument("--etcd", action="store_true")
    a.add_argument("--no-etcd", action="store_true")
    a.add_argument("--monitoring", action="store_true", default=True)
    a.add_argument("--dry-run", action="store_true")
    a.set_defaults(func=cmd_add_node)

    r = sub.add_parser("remove-node")
    r.add_argument("name")
    r.add_argument("--config", default="cluster.yml")
    r.add_argument("--dry-run", action="store_true")
    r.set_defaults(func=cmd_remove_node)

    pl = sub.add_parser("plan")
    pl.add_argument("config", nargs="?", default="cluster.yml")
    pl.set_defaults(func=cmd_plan)

    dg = sub.add_parser("diff-generated")
    dg.add_argument("config", nargs="?", default="cluster.yml")
    dg.add_argument("--show-values", action="store_true", help="print raw values, including secrets")
    dg.set_defaults(func=cmd_diff_generated)

    ae = sub.add_parser("adopt-env")
    ae.add_argument("--cluster-out", default="cluster.yml")
    ae.add_argument("--secrets-out", default="secrets.yml")
    ae.add_argument("--force", action="store_true")
    ae.add_argument("--dry-run", action="store_true")
    ae.set_defaults(func=cmd_adopt_env)

    s = sub.add_parser("status")
    s.add_argument("config", nargs="?", default="cluster.yml")
    s.set_defaults(func=cmd_status)

    d = sub.add_parser("doctor")
    d.add_argument("config", nargs="?", default="cluster.yml")
    d.set_defaults(func=cmd_doctor)

    pr = sub.add_parser("preflight-remote")
    pr.add_argument("target")
    pr.add_argument("config", nargs="?", default="cluster.yml")
    pr.add_argument("--user", default="root")
    pr.add_argument("--repo-dir", default="/opt/BELKASQL-main")
    pr.add_argument("--dry-run", action="store_true")
    pr.set_defaults(func=cmd_preflight_remote)

    bk = sub.add_parser("bootstrap-ssh-keys")
    bk.add_argument("target")
    bk.add_argument("config", nargs="?", default="cluster.yml")
    bk.add_argument("--user", default="root")
    bk.add_argument("--key-path", default=str(ROOT / "keys" / "belkasql_deploy_ed25519"))
    bk.add_argument("--dry-run", action="store_true")
    bk.set_defaults(func=cmd_bootstrap_ssh_keys)

    b = sub.add_parser("backup")
    b.add_argument("action", choices=["status", "full", "diff", "incr"])
    b.add_argument("config", nargs="?", default="cluster.yml")
    b.add_argument("--from", dest="from_node", choices=["primary", "replica", "auto"], default="primary", help="DB role to run pgBackRest from")
    b.add_argument("--user", default="root")
    b.add_argument("--dry-run", action="store_true")
    b.set_defaults(func=cmd_backup)

    rt = sub.add_parser("restore-test")
    rt.add_argument("config", nargs="?", default="cluster.yml")
    rt.add_argument("--from", dest="from_node", choices=["primary", "replica", "auto"], default="primary", help="DB role to run scratch restore from")
    rt.add_argument("--user", default="root")
    rt.add_argument("--run", action="store_true")
    rt.set_defaults(func=cmd_restore_test)

    ap = sub.add_parser("apply")
    ap.add_argument("target")
    ap.add_argument("config", nargs="?", default="cluster.yml")
    ap.add_argument("--user", default="root")
    ap.add_argument("--repo-dir", default="/opt/BELKASQL-main")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--allow-non-production", action="store_true", help="allow real apply even when production validation fails")
    ap.set_defaults(func=cmd_apply)
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ConfigError as exc:
        print(f"belkasql: {exc}", file=sys.stderr)
        raise SystemExit(2)
