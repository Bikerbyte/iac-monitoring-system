#!/usr/bin/env python3
"""
Lightweight monitoring agent for IaC lab.

This agent is intentionally direct: collect local resource data, run a few
network checks, then write enough log detail for operations troubleshooting.
"""

from __future__ import annotations

import argparse
import logging
import socket
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import psutil
import yaml


DEFAULT_CONFIG_PATH = "/etc/monitor-agent/config.yml"
DEFAULT_LOG_FILE = "/var/log/monitor-agent.log"


@dataclass
class DnsTarget:
    name: str
    host: str


@dataclass
class TcpTarget:
    name: str
    host: str
    port: int
    timeout_seconds: float


@dataclass
class AgentConfig:
    interval_seconds: int
    retry_count: int
    retry_delay_seconds: float
    log_file: str
    dns_targets: list[DnsTarget]
    tcp_targets: list[TcpTarget]


def load_config(config_path: str) -> AgentConfig:
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"config file not found: {config_path}")

    with path.open("r", encoding="utf-8") as config_file:
        raw_config = yaml.safe_load(config_file) or {}

    agent_section = raw_config.get("agent", {})
    network_section = raw_config.get("network", {})

    dns_targets = [
        DnsTarget(name=item["name"], host=item["host"])
        for item in network_section.get("dns_targets", [])
    ]

    tcp_targets = [
        TcpTarget(
            name=item["name"],
            host=item["host"],
            port=int(item.get("port", 443)),
            timeout_seconds=float(item.get("timeout_seconds", 3)),
        )
        for item in network_section.get("tcp_targets", [])
    ]

    if not dns_targets and not tcp_targets:
        raise ValueError("config must include at least one dns_targets or tcp_targets item")

    return AgentConfig(
        interval_seconds=int(agent_section.get("interval_seconds", 60)),
        retry_count=int(agent_section.get("retry_count", 2)),
        retry_delay_seconds=float(agent_section.get("retry_delay_seconds", 1)),
        log_file=str(agent_section.get("log_file", DEFAULT_LOG_FILE)),
        dns_targets=dns_targets,
        tcp_targets=tcp_targets,
    )


def configure_logging(log_file: str) -> None:
    Path(log_file).parent.mkdir(parents=True, exist_ok=True)

    logging.basicConfig(
        filename=log_file,
        level=logging.INFO,
        format="%(asctime)s level=%(levelname)s message=%(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )


def collect_resource_status() -> dict[str, Any]:
    zombie_count = 0

    for process in psutil.process_iter(["status"]):
        try:
            if process.info["status"] == psutil.STATUS_ZOMBIE:
                zombie_count += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    return {
        "cpu_percent": psutil.cpu_percent(interval=1),
        "memory_percent": psutil.virtual_memory().percent,
        "zombie_process_count": zombie_count,
    }


def check_dns(target: DnsTarget) -> tuple[bool, str]:
    try:
        socket.getaddrinfo(target.host, None)
        return True, "ok"
    except socket.gaierror as ex:
        return False, f"dns_resolution_error: {ex}"
    except OSError as ex:
        return False, f"generic_socket_error: {ex}"


def check_tcp(target: TcpTarget) -> tuple[bool, str]:
    try:
        with socket.create_connection((target.host, target.port), timeout=target.timeout_seconds):
            return True, "ok"
    except socket.timeout as ex:
        return False, f"tcp_connection_timeout: {ex}"
    except ConnectionRefusedError as ex:
        return False, f"connection_refused: {ex}"
    except OSError as ex:
        return False, f"generic_socket_error: {ex}"


def run_with_retry(
    check_name: str,
    retry_count: int,
    retry_delay_seconds: float,
    check_func: Callable[[], tuple[bool, str]],
) -> tuple[bool, str, int]:
    last_message = "not_checked"

    for attempt in range(1, retry_count + 2):
        ok, message = check_func()
        if ok:
            return True, message, attempt

        last_message = message
        logging.warning("check=%s attempt=%s result=failed reason=%s", check_name, attempt, message)

        if attempt <= retry_count:
            time.sleep(retry_delay_seconds)

    return False, last_message, retry_count + 1


def run_check_cycle(config: AgentConfig) -> None:
    resources = collect_resource_status()
    logging.info(
        "resource_status cpu_percent=%.1f memory_percent=%.1f zombie_process_count=%s",
        resources["cpu_percent"],
        resources["memory_percent"],
        resources["zombie_process_count"],
    )

    for target in config.dns_targets:
        check_name = f"dns:{target.name}"
        ok, message, attempts = run_with_retry(
            check_name,
            config.retry_count,
            config.retry_delay_seconds,
            lambda target=target: check_dns(target),
        )
        log_check_result("dns", target.name, target.host, None, ok, message, attempts)

    for target in config.tcp_targets:
        check_name = f"tcp:{target.name}"
        ok, message, attempts = run_with_retry(
            check_name,
            config.retry_count,
            config.retry_delay_seconds,
            lambda target=target: check_tcp(target),
        )
        log_check_result("tcp", target.name, target.host, target.port, ok, message, attempts)


def log_check_result(
    check_type: str,
    name: str,
    host: str,
    port: int | None,
    ok: bool,
    message: str,
    attempts: int,
) -> None:
    status = "ok" if ok else "failed"
    level = logging.INFO if ok else logging.ERROR

    logging.log(
        level,
        "network_check type=%s name=%s host=%s port=%s status=%s attempts=%s detail=%s",
        check_type,
        name,
        host,
        port or "-",
        status,
        attempts,
        message,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the IaC lab monitoring agent.")
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="Path to YAML config file.")
    parser.add_argument("--log-file", default=None, help="Override log file path from config.")
    parser.add_argument("--interval", type=int, default=None, help="Override interval seconds from config.")
    parser.add_argument("--once", action="store_true", help="Run one check cycle and exit.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        config = load_config(args.config)
        if args.log_file:
            config.log_file = args.log_file
        if args.interval:
            config.interval_seconds = args.interval

        configure_logging(config.log_file)
        logging.info("monitor-agent starting config=%s interval_seconds=%s", args.config, config.interval_seconds)

        while True:
            run_check_cycle(config)
            if args.once:
                break
            time.sleep(config.interval_seconds)

        logging.info("monitor-agent stopped")
        return 0
    except Exception:
        logging.exception("monitor-agent failed during startup or check cycle")
        return 1


if __name__ == "__main__":
    sys.exit(main())
