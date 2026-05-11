#!/usr/bin/env python3
"""
Lightweight monitoring agent for IaC lab.

This agent is intentionally direct: collect local resource data, run a few
network checks, then write enough log detail for operations troubleshooting.
"""

from __future__ import annotations

import argparse
import json
import logging
import socket
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import psutil
import yaml
from prometheus_client import Gauge, start_http_server


DEFAULT_CONFIG_PATH = "/etc/monitor-agent/config.yml"
DEFAULT_LOG_FILE = "/var/log/monitor-agent.log"
DEFAULT_METRICS_PORT = 8000
__version__ = "1.2.0"
HOSTNAME = socket.gethostname()


RESOURCE_CPU_PERCENT = Gauge("monitor_agent_cpu_percent", "CPU usage collected by the monitor agent.")
RESOURCE_MEMORY_PERCENT = Gauge("monitor_agent_memory_percent", "Memory usage collected by the monitor agent.")
RESOURCE_ZOMBIE_PROCESSES = Gauge("monitor_agent_zombie_process_count", "Zombie process count collected by the monitor agent.")
NETWORK_CHECK_SUCCESS = Gauge(
    "monitor_agent_network_check_success",
    "Network check result. 1 means success, 0 means failure.",
    ["type", "name", "host", "port"],
)
NETWORK_CHECK_ATTEMPTS = Gauge(
    "monitor_agent_network_check_attempts",
    "Attempts used by the latest network check cycle.",
    ["type", "name", "host", "port"],
)
NETWORK_CHECK_LAST_RUN = Gauge(
    "monitor_agent_network_check_last_run_timestamp_seconds",
    "Unix timestamp of the latest network check result.",
    ["type", "name", "host", "port"],
)
NETWORK_CHECK_LATENCY_MS = Gauge(
    "monitor_agent_network_check_latency_ms",
    "Latency of the latest network check in milliseconds.",
    ["type", "name", "host", "port"],
)
NETWORK_CHECK_FAILURE = Gauge(
    "monitor_agent_network_check_failure",
    "Network check failure state by failure type. 1 means the latest check failed with this failure type.",
    ["type", "name", "host", "port", "failure_type"],
)
LAST_NETWORK_FAILURE_TYPES: dict[tuple[str, str, str, str], str] = {}


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


@dataclass(frozen=True)
class CheckOutcome:
    ok: bool
    failure_type: str | None
    message: str
    latency_ms: float | None


@dataclass
class AgentConfig:
    interval_seconds: int
    retry_count: int
    retry_delay_seconds: float
    log_file: str
    metrics_enabled: bool
    metrics_listen_address: str
    metrics_port: int
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
        metrics_enabled=bool(agent_section.get("metrics_enabled", True)),
        metrics_listen_address=str(agent_section.get("metrics_listen_address", "0.0.0.0")),
        metrics_port=int(agent_section.get("metrics_port", DEFAULT_METRICS_PORT)),
        dns_targets=dns_targets,
        tcp_targets=tcp_targets,
    )


def configure_logging(log_file: str) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]

    if log_file:
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))

    logging.basicConfig(
        level=logging.INFO,
        format="%(message)s",
        handlers=handlers,
        force=True,
    )


def write_log(level: int, event: str, **fields: object) -> None:
    log_item = {
        "event": event,
        "host": HOSTNAME,
        "level": logging.getLevelName(level),
        "logged_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "version": __version__,
        **fields,
    }
    logging.log(level, json.dumps(log_item, separators=(",", ":"), sort_keys=True))


def start_metrics_endpoint(config: AgentConfig) -> None:
    if not config.metrics_enabled:
        write_log(logging.INFO, "metrics_endpoint_disabled")
        return

    start_http_server(config.metrics_port, addr=config.metrics_listen_address)
    write_log(
        logging.INFO,
        "metrics_endpoint_started",
        listen_address=config.metrics_listen_address,
        port=config.metrics_port,
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


def check_dns(target: DnsTarget) -> CheckOutcome:
    start_time = time.monotonic()

    try:
        socket.getaddrinfo(target.host, None)
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(True, None, "resolved", latency_ms)
    except socket.gaierror as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "dns_resolution_error", str(ex), latency_ms)
    except OSError as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "generic_socket_error", str(ex), latency_ms)


def check_tcp(target: TcpTarget) -> CheckOutcome:
    start_time = time.monotonic()

    try:
        with socket.create_connection((target.host, target.port), timeout=target.timeout_seconds):
            latency_ms = round((time.monotonic() - start_time) * 1000, 2)
            return CheckOutcome(True, None, "connected", latency_ms)
    except socket.timeout as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "tcp_connection_timeout", str(ex), latency_ms)
    except ConnectionRefusedError as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "tcp_connection_refused", str(ex), latency_ms)
    except OSError as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "tcp_connection_error", str(ex), latency_ms)


def run_with_retry(
    check_name: str,
    retry_count: int,
    retry_delay_seconds: float,
    check_func: Callable[[], CheckOutcome],
) -> tuple[CheckOutcome, int]:
    last_outcome = CheckOutcome(False, "not_checked", "not_checked", None)

    for attempt in range(1, retry_count + 2):
        outcome = check_func()
        if outcome.ok:
            return outcome, attempt

        last_outcome = outcome
        write_log(
            logging.WARNING,
            "check_retry_failed",
            check=check_name,
            attempt=attempt,
            failure_type=outcome.failure_type,
            detail=outcome.message,
        )

        if attempt <= retry_count:
            time.sleep(retry_delay_seconds)

    return last_outcome, retry_count + 1


def run_check_cycle(config: AgentConfig) -> None:
    resources = collect_resource_status()
    RESOURCE_CPU_PERCENT.set(resources["cpu_percent"])
    RESOURCE_MEMORY_PERCENT.set(resources["memory_percent"])
    RESOURCE_ZOMBIE_PROCESSES.set(resources["zombie_process_count"])

    write_log(
        logging.INFO,
        "metrics_collected",
        cpu_percent=round(float(resources["cpu_percent"]), 2),
        memory_percent=round(float(resources["memory_percent"]), 2),
        zombie_process_count=resources["zombie_process_count"],
    )

    for target in config.dns_targets:
        check_name = f"dns:{target.name}"
        outcome, attempts = run_with_retry(
            check_name,
            config.retry_count,
            config.retry_delay_seconds,
            lambda target=target: check_dns(target),
        )
        log_check_result("dns", target.name, target.host, None, outcome, attempts)

    for target in config.tcp_targets:
        check_name = f"tcp:{target.name}"
        outcome, attempts = run_with_retry(
            check_name,
            config.retry_count,
            config.retry_delay_seconds,
            lambda target=target: check_tcp(target),
        )
        log_check_result("tcp", target.name, target.host, target.port, outcome, attempts)


def log_check_result(
    check_type: str,
    name: str,
    host: str,
    port: int | None,
    outcome: CheckOutcome,
    attempts: int,
) -> None:
    status = "ok" if outcome.ok else "failed"
    level = logging.INFO if outcome.ok else logging.ERROR
    port_label = str(port or "")

    NETWORK_CHECK_SUCCESS.labels(check_type, name, host, port_label).set(1 if outcome.ok else 0)
    NETWORK_CHECK_ATTEMPTS.labels(check_type, name, host, port_label).set(attempts)
    NETWORK_CHECK_LAST_RUN.labels(check_type, name, host, port_label).set(time.time())
    if outcome.latency_ms is not None:
        NETWORK_CHECK_LATENCY_MS.labels(check_type, name, host, port_label).set(outcome.latency_ms)
    update_failure_metric(check_type, name, host, port_label, outcome)

    write_log(
        level,
        "network_check",
        type=check_type,
        name=name,
        target_host=host,
        port=port,
        status=status,
        ok=outcome.ok,
        attempts=attempts,
        failure_type=outcome.failure_type,
        detail=outcome.message,
        latency_ms=outcome.latency_ms,
    )


def update_failure_metric(
    check_type: str,
    name: str,
    host: str,
    port_label: str,
    outcome: CheckOutcome,
) -> None:
    check_key = (check_type, name, host, port_label)
    previous_failure_type = LAST_NETWORK_FAILURE_TYPES.pop(check_key, None)

    if previous_failure_type:
        NETWORK_CHECK_FAILURE.labels(check_type, name, host, port_label, previous_failure_type).set(0)

    if outcome.ok or not outcome.failure_type:
        return

    NETWORK_CHECK_FAILURE.labels(check_type, name, host, port_label, outcome.failure_type).set(1)
    LAST_NETWORK_FAILURE_TYPES[check_key] = outcome.failure_type


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the IaC lab monitoring agent.")
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="Path to YAML config file.")
    parser.add_argument("--log-file", default=None, help="Override log file path from config.")
    parser.add_argument("--interval", type=int, default=None, help="Override interval seconds from config.")
    parser.add_argument("--metrics-port", type=int, default=None, help="Override Prometheus metrics endpoint port.")
    parser.add_argument("--disable-metrics", action="store_true", help="Disable Prometheus metrics endpoint.")
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
        if args.metrics_port:
            config.metrics_port = args.metrics_port
        if args.disable_metrics:
            config.metrics_enabled = False

        configure_logging(config.log_file)
        write_log(
            logging.INFO,
            "agent_started",
            config=args.config,
            interval_seconds=config.interval_seconds,
            metrics_enabled=config.metrics_enabled,
            dns_targets=[target.__dict__ for target in config.dns_targets],
            tcp_targets=[target.__dict__ for target in config.tcp_targets],
        )
        start_metrics_endpoint(config)

        while True:
            run_check_cycle(config)
            if args.once:
                break
            time.sleep(config.interval_seconds)

        write_log(logging.INFO, "agent_stopped")
        return 0
    except Exception as ex:
        if not logging.getLogger().handlers:
            logging.basicConfig(level=logging.INFO, format="%(message)s")
        write_log(
            logging.ERROR,
            "agent_failed",
            failure_type=type(ex).__name__,
            message=str(ex),
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
