from __future__ import annotations

import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import belkasql as cli  # noqa: E402
from belkasql_generate import ConfigError, build, load_simple_yaml, parse_scalar, validate, validate_production  # noqa: E402


class BelkaSqlTests(unittest.TestCase):
    def test_example_config_builds(self) -> None:
        config = load_simple_yaml(ROOT / "cluster.example.yml")
        validate(config)
        outputs = build(config)

        self.assertIn(Path("db-node/env/city-a.env"), outputs)
        self.assertIn(Path("lb-node/env/cloud-lb-a.env"), outputs)
        self.assertIn("DB_NODES=city-a=10.77.0.2", outputs[Path("lb-node/env/cloud-lb-a.env")])

    def test_production_validation_rejects_placeholders(self) -> None:
        config = load_simple_yaml(ROOT / "cluster.example.yml")

        with self.assertRaises(ConfigError) as raised:
            validate_production(config)

        self.assertIn("placeholder", str(raised.exception))

    def test_apply_archive_uses_clean_staging(self) -> None:
        config = load_simple_yaml(ROOT / "cluster.example.yml")
        outputs = build(config)

        with tempfile.TemporaryDirectory(prefix="belkasql-test-generated-") as tmp:
            generated = Path(tmp)
            with redirect_stdout(StringIO()):
                cli.write_outputs(outputs, generated, dry_run=False)
            archive = cli.create_repo_archive(generated)
            try:
                with tarfile.open(archive, "r:gz") as tar:
                    names = set(tar.getnames())
            finally:
                archive.unlink(missing_ok=True)

        self.assertIn("scripts/belkasql.py", names)
        self.assertIn("db-node/env/city-a.env", names)
        self.assertNotIn("db-node/env/city-a.env.bak-beget", names)
        self.assertFalse(any(name.startswith(".git/") for name in names))
        self.assertFalse(any(name in {"cluster.yml", "secrets.yml"} for name in names))

    def test_secret_values_are_redacted_by_default(self) -> None:
        self.assertEqual(cli.display_value("POSTGRES_SUPERUSER_PASSWORD", "secret", show_values=False), "<redacted>")
        self.assertEqual(cli.display_value("DB_NODES", "city-a=10.77.0.2", show_values=False), "city-a=10.77.0.2")

    def test_remote_role_commands_preflight_and_create_network(self) -> None:
        config = load_simple_yaml(ROOT / "cluster.example.yml")
        city_a = next(node for node in config["nodes"] if node["name"] == "city-a")
        command = cli.remote_role_command(city_a, "/opt/BELKASQL-main", config)

        self.assertIn("docker network inspect belkasql_belka-net", command)
        self.assertIn("docker compose --env-file env/city-a.env -f docker-compose.yml config -q", command)

    def test_windows_remote_role_command_uses_powershell(self) -> None:
        config = load_simple_yaml(ROOT / "cluster.example.yml")
        city_a = dict(next(node for node in config["nodes"] if node["name"] == "city-a"))
        city_a["os"] = "windows"
        command = cli.remote_role_command(city_a, r"D:\GitRepositories\BELKASQL-main", config)

        self.assertIn("powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand", command)

    def test_windows_remote_paths(self) -> None:
        node = {"name": "city-a", "os": "windows"}
        archive = Path("belkasql-apply-test.tar.gz")

        self.assertEqual(cli.remote_archive_path(node, archive), "C:/Windows/Temp/belkasql-apply-test.tar.gz")
        self.assertIn("EncodedCommand", cli.remote_prepare_command(node, r"D:\GitRepositories\BELKASQL-main"))
        self.assertIn("EncodedCommand", cli.remote_extract_command(node, "C:/Windows/Temp/a.tar.gz", r"D:\GitRepositories\BELKASQL-main"))

    def test_linux_remote_extract_can_use_sudo(self) -> None:
        node = {"name": "city-c", "os": "linux", "ssh_sudo": True}

        self.assertIn("sudo tar -xzf", cli.remote_extract_command(node, "/tmp/a.tar.gz", "/opt/BELKASQL-main"))

    def test_double_quoted_yaml_unescapes_windows_path(self) -> None:
        self.assertEqual(parse_scalar(r'"D:\\GitRepositories\\BELKASQL-main"'), r"D:\GitRepositories\BELKASQL-main")

    def test_node_ssh_password_from_config(self) -> None:
        node = {"name": "city-a"}
        config = {"ssh": {"passwords": {"city-a": "secret"}}}

        self.assertEqual(cli.node_ssh_password(node, config), "secret")

    def test_node_ssh_identity_file_prefers_node_value(self) -> None:
        node = {"name": "city-a", "ssh_identity_file": "keys/node"}
        config = {"ssh": {"identity_file": "keys/global", "passwords": {"city-a": "secret"}}}

        self.assertTrue(cli.node_ssh_identity_file(node, config).endswith(str(Path("keys") / "node")))

    def test_native_ssh_args_include_identity_file(self) -> None:
        args = cli.ssh_args(2222, "keys/deploy")

        self.assertIn("-i", args)
        self.assertIn("keys/deploy", args)
        self.assertIn("BatchMode=yes", args)
        self.assertIn("StrictHostKeyChecking=accept-new", args)
        self.assertEqual(args[-2:], ["-p", "2222"])

    def test_windows_install_public_key_uses_admin_authorized_keys(self) -> None:
        node = {"name": "city-a", "os": "windows"}
        command = cli.install_public_key_command(node, "ssh-ed25519 AAAA test")

        self.assertIn("EncodedCommand", command)
        decoded = command.rsplit(" ", 1)[-1]
        # UTF-16LE encoded PowerShell should contain the target file path when decoded.
        import base64

        script = base64.b64decode(decoded).decode("utf-16le")
        self.assertIn("C:\\ProgramData\\ssh\\administrators_authorized_keys", script)

    def test_remote_preflight_windows_uses_powershell(self) -> None:
        config = load_simple_yaml(ROOT / "cluster.example.yml")
        node = {"name": "city-a", "os": "windows"}

        self.assertIn("EncodedCommand", cli.remote_preflight_command(node, r"D:\GitRepositories\BELKASQL-main", config))

    def test_apply_without_production_flag_is_blocked_for_example_config(self) -> None:
        parser = cli.parser()
        args = parser.parse_args(["apply", "city-a", "cluster.example.yml"])

        with self.assertRaises(ConfigError):
            cli.cmd_apply(args)

    def test_adopt_env_dry_run_redacts_secrets(self) -> None:
        parser = cli.parser()
        out = StringIO()

        with tempfile.TemporaryDirectory(prefix="belkasql-adopt-test-") as tmp:
            args = parser.parse_args([
                "adopt-env",
                "--cluster-out",
                str(Path(tmp) / "cluster.yml"),
                "--secrets-out",
                str(Path(tmp) / "secrets.yml"),
                "--dry-run",
            ])
            with redirect_stdout(out):
                self.assertEqual(cli.cmd_adopt_env(args), 0)

        text = out.getvalue()
        self.assertIn("cluster.yml", text)
        self.assertIn("secrets.yml", text)
        self.assertIn("city-a", text)
        self.assertNotIn("POSTGRES_SUPERUSER_PASSWORD=", text)


if __name__ == "__main__":
    unittest.main()
