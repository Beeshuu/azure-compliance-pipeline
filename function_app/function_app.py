import json
import logging
import os
from collections import Counter

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions

FINDING_MARKER = "COMPLIANCE_FINDING "
SCAN_MARKER = "COMPLIANCE_SCAN_COMPLETED "

QUERY = """
policyresources
| where type =~ 'microsoft.policyinsights/policystates'
| where tostring(properties.complianceState) =~ 'NonCompliant'
| extend policyAssignmentId = tolower(tostring(properties.policyAssignmentId))
| join kind=leftouter (
    policyresources
    | where type =~ 'microsoft.authorization/policyassignments'
    | project policyAssignmentId = tolower(id), displayName = tostring(properties.displayName)
  ) on policyAssignmentId
| project
    resourceId = tolower(tostring(properties.resourceId)),
    resourceType = tostring(properties.resourceType),
    resourceGroup = tostring(properties.resourceGroup),
    subscriptionId = tostring(properties.subscriptionId),
    policyAssignment = iff(isempty(displayName), tostring(properties.policyAssignmentName), displayName),
    policyAssignmentId,
    policyDefinitionName = tostring(properties.policyDefinitionName),
    policyDefinitionAction = tostring(properties.policyDefinitionAction),
    policySetDefinitionName = tostring(properties.policySetDefinitionName),
    policyDefinitionReferenceId = tostring(properties.policyDefinitionReferenceId),
    lastEvaluated = tostring(properties.timestamp)
| order by resourceId asc, policyAssignmentId asc, policyDefinitionReferenceId asc, policyDefinitionName asc
"""

logger = logging.getLogger("compliance")
logger.setLevel(logging.INFO)
logging.getLogger("azure").setLevel(logging.WARNING)


def subscription_ids(environ=os.environ) -> list[str]:
    raw = environ.get("SCAN_SUBSCRIPTION_IDS", "")
    ids = [s.strip() for s in raw.split(",") if s.strip()]
    if not ids:
        raise ValueError("SCAN_SUBSCRIPTION_IDS must list at least one subscription ID")
    return ids


def find_non_compliant(client, subscriptions):
    skip_token = None
    while True:
        options = QueryRequestOptions(
            result_format="objectArray", top=1000, skip_token=skip_token
        )
        request = QueryRequest(
            subscriptions=subscriptions, query=QUERY, options=options
        )
        response = client.resources(request)
        yield from response.data or []
        skip_token = response.skip_token
        if not skip_token:
            return


def run_scan(subscriptions, client=None) -> dict:
    client = client or ResourceGraphClient(DefaultAzureCredential())
    findings, resources, by_assignment = 0, set(), Counter()
    for row in find_non_compliant(client, subscriptions):
        logger.warning("%s%s", FINDING_MARKER, json.dumps(row, separators=(",", ":")))
        findings += 1
        resources.add(row["resourceId"])
        by_assignment[row["policyAssignment"]] += 1

    summary = {
        "findings": findings,
        "nonCompliantResources": len(resources),
        "byPolicyAssignment": dict(by_assignment),
    }
    logger.info("%s%s", SCAN_MARKER, json.dumps(summary, separators=(",", ":")))
    return summary


app = func.FunctionApp()


@app.timer_trigger(schedule="%SCAN_SCHEDULE%", arg_name="timer")
def compliance_scan(timer: func.TimerRequest) -> None:
    run_scan(subscription_ids())
