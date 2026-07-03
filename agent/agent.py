#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SRE monitoring agent for the IaC monitoring lab.

Collected metrics
-----------------
  - CPU utilisation
  - Memory utilisation
  - Zombie process count
  - DNS resolution health and latency
  - TCP reachability, retry count, latency, and failure classification

The agent keeps two outputs on purpose: structured JSON logs for operations
troubleshooting, and Prometheus gauges for dashboarding and alerting.

This file is intentionally plain Python. The goal is not to hide monitoring
logic behind abstractions; the goal is to make each operational signal easy to
trace when something is broken at 03:00.
"""

from __future__ import annotations

import argparse
import json
import logging
import socket
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

import psutil
import yaml
from prometheus_client import Gauge, start_http_server


DEFAULT_CONFIG_PATH = "/etc/monitor-agent/config.yml"
DEFAULT_LOG_FILE = "/var/log/monitor-agent.log"
DEFAULT_METRICS_PORT = 8000

# Bump this on each agent release. The value is included in every log entry so
# mixed-version hosts are easy to spot during incident review.
__version__ = "1.2.0"

# Host identity is attached to every JSON log. Prometheus has labels; log files
# need their own host field when shipped into a central collector.
HOSTNAME = socket.gethostname()


# ---------------------------------------------------------------------------
# Prometheus metrics
#
# Keep metric names stable. Grafana dashboards, PrometheusRule alerts, and
# smoke tests can depend on these names after the agent is deployed.
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class DnsTarget:
    name: str
    host: str


@dataclass(frozen=True)
class TcpTarget:
    name: str
    host: str
    port: int
    timeout_seconds: float


@dataclass(frozen=True)
class ResourceStatus:
    cpu_percent: float
    memory_percent: float
    zombie_process_count: int


@dataclass(frozen=True)
class CheckOutcome:
    """Common result shape for DNS and TCP checks.

    failure_type examples:
      - dns_resolution_error
      - tcp_connection_timeout
      - tcp_connection_refused
      - tcp_connection_error
    """

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


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def load_config(config_path: str) -> AgentConfig:
    """Load YAML config and normalize defaults used by systemd and containers.

    The same config file is mounted into the Kubernetes container image and
    copied to /etc/monitor-agent/config.yml by Ansible in VM mode. Keeping this
    path stable makes the agent behave the same in both deployment modes.
    """
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"config file not found: {config_path}")

    with path.open("r", encoding="utf-8") as config_file:
        raw_config = yaml.safe_load(config_file) or {}

    agent_section = raw_config.get("agent", {})
    network_section = raw_config.get("network", {})

    # DNS targets validate name resolution only.
    dns_targets = [
        DnsTarget(name=item["name"], host=item["host"])
        for item in network_section.get("dns_targets", [])
    ]

    # TCP targets validate both resolution and connection reachability.
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


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def configure_logging(log_file: str) -> None:
    """Log to stdout for containers/journald and optionally to a local file."""
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
    """Write one JSON event.

    Example:
      {"event":"network_check","host":"node-01","status":"ok",...}

    JSON logs are intentionally single-line so journalctl, Docker logs, Loki,
    or a simple grep can all consume them without special parsing rules.
    """
    log_item = {
        "event": event,
        "host": HOSTNAME,
        "level": logging.getLevelName(level),
        "logged_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "version": __version__,
        **fields,
    }
    logging.log(level, json.dumps(log_item, separators=(",", ":"), sort_keys=True))


# ---------------------------------------------------------------------------
# Prometheus endpoint
# ---------------------------------------------------------------------------

def start_metrics_endpoint(config: AgentConfig) -> None:
    """Start the /metrics endpoint scraped by Prometheus."""
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


# ---------------------------------------------------------------------------
# Linux resource checks
# ---------------------------------------------------------------------------

def collect_resource_status() -> ResourceStatus:
    """Collect host-level resource signals for both logs and Prometheus gauges.

    psutil is used here instead of hand-parsing /proc so the same code path can
    run in Linux servers, k8s containers, and local unit tests. The meaning is
    still host-style monitoring:
      cpu_percent    -> CPU utilisation sample
      memory_percent -> used memory percentage
      zombie count   -> processes stuck in Z state
        E.g. 1 (systemd) S 0 1 1 0
    """
    zombie_count = 0

    for process in psutil.process_iter(["status"]):
        try:
            if process.info["status"] == psutil.STATUS_ZOMBIE:
                zombie_count += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    return ResourceStatus(
        cpu_percent=round(float(psutil.cpu_percent(interval=1)), 2),
        memory_percent=round(float(psutil.virtual_memory().percent), 2),
        zombie_process_count=zombie_count,
    )


# ---------------------------------------------------------------------------
# Network diagnostics
# ---------------------------------------------------------------------------

def check_dns(target: DnsTarget) -> CheckOutcome:
    """Resolve a DNS target and classify socket failures for alert context.

    We keep DNS as its own check because a failed service can be caused by
    name resolution even when TCP and the application are healthy.
    """
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
    """Attempt a TCP connection and return a classified result.

    Steps:
      1. Resolve host with getaddrinfo() so DNS errors are explicit.
      2. Try each returned address until one TCP connect succeeds.
      3. Report the last useful failure type if all addresses fail.

    This mirrors the manual troubleshooting flow:
      nslookup service.example.com
      nc -vz service.example.com 443
    """
    start_time = time.monotonic()

    try:
        addresses = socket.getaddrinfo(
            target.host,
            target.port,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
    except socket.gaierror as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "dns_resolution_error", str(ex), latency_ms)
    except OSError as ex:
        latency_ms = round((time.monotonic() - start_time) * 1000, 2)
        return CheckOutcome(False, "tcp_connection_error", str(ex), latency_ms)

    last_error: Exception | None = None

    for family, socktype, proto, _, sockaddr in addresses:
        sock = socket.socket(family, socktype, proto)
        sock.settimeout(target.timeout_seconds)

        try:
            sock.connect(sockaddr)
            latency_ms = round((time.monotonic() - start_time) * 1000, 2)
            return CheckOutcome(True, None, "connected", latency_ms)
        except socket.timeout as ex:
            last_error = ex
        except ConnectionRefusedError as ex:
            latency_ms = round((time.monotonic() - start_time) * 1000, 2)
            return CheckOutcome(False, "tcp_connection_refused", str(ex), latency_ms)
        except OSError as ex:
            last_error = ex
        finally:
            sock.close()

    latency_ms = round((time.monotonic() - start_time) * 1000, 2)
    failure_type = (
        "tcp_connection_timeout"
        if isinstance(last_error, socket.timeout)
        else "tcp_connection_error"
    )

    return CheckOutcome(
        False,
        failure_type,
        str(last_error) if last_error else "no address succeeded",
        latency_ms,
    )


def run_with_retry(
    check_name: str,
    retry_count: int,
    retry_delay_seconds: float,
    check_func: Callable[[], CheckOutcome],
) -> tuple[CheckOutcome, int]:
    """Run one check with retry and log failed attempts as operational clues.

    retry_count means "extra attempts after the first try".
      retry_count=2 -> attempt 1 + retry 1 + retry 2 = 3 total attempts
    """
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


# ---------------------------------------------------------------------------
# Main collection cycle
# ---------------------------------------------------------------------------

def run_check_cycle(config: AgentConfig) -> None:
    """Execute one full collection cycle.

    Cycle order is deliberate:
      1. Collect local resource metrics.
      2. Publish gauges before network checks.
      3. Run DNS checks.
      4. Run TCP checks.

    That order gives Prometheus a fresh local baseline even if a later network
    target is slow or failing.
    """
    resources = collect_resource_status()
    RESOURCE_CPU_PERCENT.set(resources.cpu_percent)
    RESOURCE_MEMORY_PERCENT.set(resources.memory_percent)
    RESOURCE_ZOMBIE_PROCESSES.set(resources.zombie_process_count)

    write_log(
        logging.INFO,
        "metrics_collected",
        **asdict(resources),
    )

    if resources.zombie_process_count:
        write_log(
            logging.WARNING,
            "zombie_processes_found",
            zombie_process_count=resources.zombie_process_count,
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
    """Update Prometheus gauges and emit one JSON log per completed check."""
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


# ---------------------------------------------------------------------------
# Failure-state tracking
# ---------------------------------------------------------------------------

def update_failure_metric(
    check_type: str,
    name: str,
    host: str,
    port_label: str,
    outcome: CheckOutcome,
) -> None:
    """Track the latest failure type per target.

    Prometheus gauges are sticky until explicitly changed. If a target changes
    from timeout -> refused -> ok, the previous failure label must be reset or
    Grafana will show stale failure states.
    """
    check_key = (check_type, name, host, port_label)
    previous_failure_type = LAST_NETWORK_FAILURE_TYPES.pop(check_key, None)

    NETWORK_CHECK_FAILURE.labels(check_type, name, host, port_label, "none").set(0)

    if previous_failure_type:
        NETWORK_CHECK_FAILURE.labels(check_type, name, host, port_label, previous_failure_type).set(0)

    if outcome.ok or not outcome.failure_type:
        return

    NETWORK_CHECK_FAILURE.labels(check_type, name, host, port_label, outcome.failure_type).set(1)
    LAST_NETWORK_FAILURE_TYPES[check_key] = outcome.failure_type


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    """Define CLI flags used by containers, systemd, and smoke tests."""
    parser = argparse.ArgumentParser(
        description="Run the IaC lab monitoring agent.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="Path to YAML config file.")
    parser.add_argument("--log-file", default=None, help="Override log file path from config.")
    parser.add_argument("--interval", type=int, default=None, help="Override interval seconds from config.")
    parser.add_argument("--metrics-port", type=int, default=None, help="Override Prometheus metrics endpoint port.")
    parser.add_argument("--disable-metrics", action="store_true", help="Disable Prometheus metrics endpoint.")
    parser.add_argument("--once", action="store_true", help="Run one check cycle and exit.")
    return parser.parse_args()


def apply_cli_overrides(config: AgentConfig, args: argparse.Namespace) -> AgentConfig:
    """Keep YAML as the default source of truth, then apply smoke-test overrides."""
    if args.log_file:
        config.log_file = args.log_file
    if args.interval:
        config.interval_seconds = args.interval
    if args.metrics_port:
        config.metrics_port = args.metrics_port
    if args.disable_metrics:
        config.metrics_enabled = False
    return config


def main() -> int:
    """Entry point.

    Example:
      python3 agent.py --config /etc/monitor-agent/config.yml --once
    """
    args = parse_args()

    try:
        config = apply_cli_overrides(load_config(args.config), args)
        configure_logging(config.log_file)
        write_log(
            logging.INFO,
            "agent_started",
            config=args.config,
            interval_seconds=config.interval_seconds,
            metrics_enabled=config.metrics_enabled,
            dns_targets=[asdict(target) for target in config.dns_targets],
            tcp_targets=[asdict(target) for target in config.tcp_targets],
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
