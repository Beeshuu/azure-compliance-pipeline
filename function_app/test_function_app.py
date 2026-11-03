import json
import logging
import re
from pathlib import Path
from types import SimpleNamespace

import pytest

from function_app import (
    FINDING_MARKER,
    QUERY,
    SCAN_MARKER,
    find_non_compliant,
    run_scan,
    subscription_ids,
)

SUB = "11111111-1111-1111-1111-111111111111"


def row(resource, assignment="Storage baseline"):
    return {"resourceId": resource, "policyAssignment": assignment}


class FakeResourceGraph:
    def __init__(self, *pages):
        self.pages = list(pages)
        self.requests = []

    def resources(self, request):
        self.requests.append(request)
        data, token = self.pages[len(self.requests) - 1]
        return SimpleNamespace(data=data, skip_token=token)


def test_subscription_ids_parses_comma_separated_list():
    assert subscription_ids({"SCAN_SUBSCRIPTION_IDS": " a , b,"}) == ["a", "b"]


@pytest.mark.parametrize("value", ["", " , "])
def test_subscription_ids_rejects_empty(value):
    with pytest.raises(ValueError, match="SCAN_SUBSCRIPTION_IDS"):
        subscription_ids({"SCAN_SUBSCRIPTION_IDS": value})


def test_find_non_compliant_follows_skip_tokens():
    client = FakeResourceGraph(([row("a"), row("b")], "page-2"), ([row("c")], None))

    rows = list(find_non_compliant(client, [SUB]))

    assert [r["resourceId"] for r in rows] == ["a", "b", "c"]
    assert [r.options.skip_token for r in client.requests] == [None, "page-2"]
    assert all(r.subscriptions == [SUB] for r in client.requests)


def test_find_non_compliant_handles_empty_result():
    assert list(find_non_compliant(FakeResourceGraph((None, None)), [SUB])) == []


def test_run_scan_logs_each_finding_and_a_summary(caplog):
    client = FakeResourceGraph(([row("a"), row("a", "Other"), row("b")], None))

    with caplog.at_level(logging.INFO, logger="compliance"):
        summary = run_scan([SUB], client=client)

    messages = [r.getMessage() for r in caplog.records]
    findings = [m for m in messages if m.startswith(FINDING_MARKER)]
    assert len(findings) == 3
    assert json.loads(findings[0][len(FINDING_MARKER) :]) == row("a")

    summaries = [m for m in messages if m.startswith(SCAN_MARKER)]
    assert [json.loads(s[len(SCAN_MARKER) :]) for s in summaries] == [summary]
    assert summary == {
        "findings": 3,
        "nonCompliantResources": 2,
        "byPolicyAssignment": {"Storage baseline": 2, "Other": 1},
    }


def test_run_scan_raises_without_logging_completion(caplog):
    class Broken:
        def resources(self, request):
            raise PermissionError("AuthorizationFailed")

    with caplog.at_level(logging.INFO), pytest.raises(PermissionError):
        run_scan([SUB], client=Broken())

    assert not any(r.getMessage().startswith(SCAN_MARKER) for r in caplog.records)


def test_log_contract_matches_alert_queries():
    tf = (Path(__file__).resolve().parents[1] / "infra" / "main.tf").read_text()
    assert f'finding_marker = "{FINDING_MARKER}"' in tf
    assert f'scan_marker    = "{SCAN_MARKER}"' in tf

    projected = QUERY.rsplit("| project", 1)[1]
    columns = set(re.findall(r"^\s+(\w+)(?:\s*=|,)", projected, re.MULTILINE))
    fields = set(re.findall(r"\bf\.(\w+)", tf))
    assert fields and fields <= columns
