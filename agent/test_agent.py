"""Unit tests for the monitor-agent.

Focused on pure logic (config parsing, retry policy, failure-state tracking)
and the network check branches via socket-level mocks. Avoids touching real
DNS / TCP, real disks (beyond tmp_path), and the running Prometheus gauges
where possible.
"""

from __future__ import annotations

import json
import logging
import socket
from pathlib import Path
from typing import Iterator
from unittest.mock import patch

import pytest

import agent


# ---------------------------------------------------------------------------
# load_config
# ---------------------------------------------------------------------------


def _write_config(tmp_path: Path, body: str) -> Path:
    config_path = tmp_path / "config.yml"
    config_path.write_text(body, encoding="utf-8")
    return config_path


def test_load_config_happy_path(tmp_path: Path) -> None:
    config_path = _write_config(
        tmp_path,
        """
        agent:
          interval_seconds: 30
          retry_count: 4
          retry_delay_seconds: 0.5
          log_file: /tmp/agent.log
          metrics_enabled: false
          metrics_listen_address: 127.0.0.1
          metrics_port: 9000
        network:
          dns_targets:
            - name: gh
              host: github.com
          tcp_targets:
            - name: g
              host: google.com
              port: 443
              timeout_seconds: 2
        """,
    )

    config = agent.load_config(str(config_path))

    assert config.interval_seconds == 30
    assert config.retry_count == 4
    assert config.retry_delay_seconds == 0.5
    assert config.log_file == "/tmp/agent.log"
    assert config.metrics_enabled is False
    assert config.metrics_listen_address == "127.0.0.1"
    assert config.metrics_port == 9000
    assert config.dns_targets == [agent.DnsTarget(name="gh", host="github.com")]
    assert config.tcp_targets == [
        agent.TcpTarget(name="g", host="google.com", port=443, timeout_seconds=2.0)
    ]


def test_load_config_applies_defaults_when_agent_section_missing(tmp_path: Path) -> None:
    config_path = _write_config(
        tmp_path,
        """
        network:
          tcp_targets:
            - name: g
              host: google.com
        """,
    )

    config = agent.load_config(str(config_path))

    assert config.interval_seconds == 60
    assert config.retry_count == 2
    assert config.metrics_port == agent.DEFAULT_METRICS_PORT
    # tcp_targets default port / timeout
    assert config.tcp_targets[0].port == 443
    assert config.tcp_targets[0].timeout_seconds == 3.0


def test_load_config_missing_file_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        agent.load_config(str(tmp_path / "does-not-exist.yml"))


def test_load_config_requires_at_least_one_target(tmp_path: Path) -> None:
    config_path = _write_config(tmp_path, "agent: {}\nnetwork: {}\n")

    with pytest.raises(ValueError, match="at least one"):
        agent.load_config(str(config_path))


# ---------------------------------------------------------------------------
# check_dns
# ---------------------------------------------------------------------------


def test_check_dns_success() -> None:
    with patch.object(agent.socket, "getaddrinfo", return_value=[("addr",)]):
        outcome = agent.check_dns(agent.DnsTarget(name="x", host="example.com"))

    assert outcome.ok is True
    assert outcome.failure_type is None
    assert outcome.latency_ms is not None and outcome.latency_ms >= 0


def test_check_dns_gaierror_classified_as_dns_resolution_error() -> None:
    with patch.object(agent.socket, "getaddrinfo", side_effect=socket.gaierror("nodename nor servname")):
        outcome = agent.check_dns(agent.DnsTarget(name="x", host="example.invalid"))

    assert outcome.ok is False
    assert outcome.failure_type == "dns_resolution_error"


def test_check_dns_other_oserror_classified_as_generic() -> None:
    with patch.object(agent.socket, "getaddrinfo", side_effect=OSError("network unreachable")):
        outcome = agent.check_dns(agent.DnsTarget(name="x", host="example.com"))

    assert outcome.ok is False
    assert outcome.failure_type == "generic_socket_error"


# ---------------------------------------------------------------------------
# check_tcp
# ---------------------------------------------------------------------------


def _tcp_target() -> agent.TcpTarget:
    return agent.TcpTarget(name="t", host="example.com", port=443, timeout_seconds=1.0)


def test_check_tcp_success() -> None:
    class FakeSocket:
        def __enter__(self) -> "FakeSocket":
            return self

        def __exit__(self, *exc_info: object) -> None:
            return None

    with patch.object(agent.socket, "create_connection", return_value=FakeSocket()):
        outcome = agent.check_tcp(_tcp_target())

    assert outcome.ok is True
    assert outcome.failure_type is None


def test_check_tcp_timeout_classified() -> None:
    with patch.object(agent.socket, "create_connection", side_effect=socket.timeout("timed out")):
        outcome = agent.check_tcp(_tcp_target())

    assert outcome.ok is False
    assert outcome.failure_type == "tcp_connection_timeout"


def test_check_tcp_refused_classified() -> None:
    with patch.object(agent.socket, "create_connection", side_effect=ConnectionRefusedError("refused")):
        outcome = agent.check_tcp(_tcp_target())

    assert outcome.ok is False
    assert outcome.failure_type == "tcp_connection_refused"


def test_check_tcp_other_oserror_classified() -> None:
    with patch.object(agent.socket, "create_connection", side_effect=OSError("network down")):
        outcome = agent.check_tcp(_tcp_target())

    assert outcome.ok is False
    assert outcome.failure_type == "tcp_connection_error"


# ---------------------------------------------------------------------------
# run_with_retry
# ---------------------------------------------------------------------------


def _outcomes(seq: list[agent.CheckOutcome]) -> Iterator[agent.CheckOutcome]:
    return iter(seq)


@pytest.fixture(autouse=True)
def _no_sleep() -> Iterator[None]:
    with patch.object(agent.time, "sleep") as _:
        yield


def test_run_with_retry_returns_on_first_success() -> None:
    success = agent.CheckOutcome(True, None, "ok", 1.0)
    seq = _outcomes([success])

    outcome, attempts = agent.run_with_retry("dns:x", retry_count=3, retry_delay_seconds=0.0,
                                             check_func=lambda: next(seq))

    assert outcome is success
    assert attempts == 1


def test_run_with_retry_recovers_on_second_attempt() -> None:
    fail = agent.CheckOutcome(False, "dns_resolution_error", "nope", 1.0)
    success = agent.CheckOutcome(True, None, "ok", 1.0)
    seq = _outcomes([fail, success])

    outcome, attempts = agent.run_with_retry("dns:x", retry_count=2, retry_delay_seconds=0.0,
                                             check_func=lambda: next(seq))

    assert outcome is success
    assert attempts == 2


def test_run_with_retry_exhausts_and_returns_last_failure() -> None:
    fail1 = agent.CheckOutcome(False, "tcp_connection_timeout", "to", 1.0)
    fail2 = agent.CheckOutcome(False, "tcp_connection_refused", "ref", 1.0)
    fail3 = agent.CheckOutcome(False, "tcp_connection_error", "err", 1.0)
    seq = _outcomes([fail1, fail2, fail3])

    outcome, attempts = agent.run_with_retry("tcp:x", retry_count=2, retry_delay_seconds=0.0,
                                             check_func=lambda: next(seq))

    assert outcome is fail3
    assert attempts == 3  # retry_count + 1


# ---------------------------------------------------------------------------
# update_failure_metric — state-tracking across cycles
# ---------------------------------------------------------------------------


def test_update_failure_metric_clears_previous_failure_type_on_recovery() -> None:
    agent.LAST_NETWORK_FAILURE_TYPES.clear()
    labels = ("tcp", "svc", "10.0.0.1", "443")

    # Cycle 1: first failure with timeout
    agent.update_failure_metric(
        *labels,
        outcome=agent.CheckOutcome(False, "tcp_connection_timeout", "to", 5.0),
    )
    assert agent.LAST_NETWORK_FAILURE_TYPES[labels] == "tcp_connection_timeout"
    assert (
        agent.NETWORK_CHECK_FAILURE.labels(*labels, "tcp_connection_timeout")._value.get() == 1
    )

    # Cycle 2: recovers — previous failure_type gauge must be cleared
    agent.update_failure_metric(
        *labels,
        outcome=agent.CheckOutcome(True, None, "ok", 5.0),
    )
    assert labels not in agent.LAST_NETWORK_FAILURE_TYPES
    assert (
        agent.NETWORK_CHECK_FAILURE.labels(*labels, "tcp_connection_timeout")._value.get() == 0
    )
    assert agent.NETWORK_CHECK_FAILURE.labels(*labels, "none")._value.get() == 0


def test_update_failure_metric_swaps_failure_type_across_cycles() -> None:
    agent.LAST_NETWORK_FAILURE_TYPES.clear()
    labels = ("tcp", "svc2", "10.0.0.2", "443")

    agent.update_failure_metric(
        *labels,
        outcome=agent.CheckOutcome(False, "tcp_connection_timeout", "to", 5.0),
    )
    agent.update_failure_metric(
        *labels,
        outcome=agent.CheckOutcome(False, "tcp_connection_refused", "ref", 5.0),
    )

    assert agent.LAST_NETWORK_FAILURE_TYPES[labels] == "tcp_connection_refused"
    assert (
        agent.NETWORK_CHECK_FAILURE.labels(*labels, "tcp_connection_timeout")._value.get() == 0
    )
    assert (
        agent.NETWORK_CHECK_FAILURE.labels(*labels, "tcp_connection_refused")._value.get() == 1
    )


# ---------------------------------------------------------------------------
# write_log — JSON shape
# ---------------------------------------------------------------------------


def test_write_log_emits_json_with_required_fields(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO)

    agent.write_log(logging.INFO, "unit_test_event", target="example.com", attempts=2)

    assert len(caplog.records) >= 1
    record = caplog.records[-1]
    payload = json.loads(record.getMessage())
    assert payload["event"] == "unit_test_event"
    assert payload["level"] == "INFO"
    assert payload["host"] == agent.HOSTNAME
    assert payload["version"] == agent.__version__
    assert payload["target"] == "example.com"
    assert payload["attempts"] == 2
    assert "logged_at" in payload
