---
name: azure-governance
description: >
  Assess Azure governance across management hierarchy, Azure Policy, RBAC,
  privileged access, tags, naming, resource locks, cost controls, and orphaned
  resource lifecycle. Use for governance reviews, compliance posture, ownership
  gaps, policy exemptions, excessive access, resource hygiene, idle-resource
  governance, and safe remediation planning at scale.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Governance

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Perform a read-only Azure governance assessment across management groups,
subscriptions, resource groups, and resources. Evaluate whether organizational
standards are inherited, measurable, owned, and safely enforced.

Use Microsoft Azure governance and FinOps Toolkit guidance as authoritative.
Use the community `azure-orphan-resources` workbook only as supplemental
candidate-detection coverage. A resource configuration match is not proof that
the resource is unused or safe to delete.

## When to use this skill
- The user asks for an Azure governance or compliance review
- The user wants to assess management groups, Policy, RBAC, tags, or locks
- The user wants to identify unowned, untagged, or orphaned resources
- The user wants governance controls for cost and resource lifecycle
- The user requests an audit-readiness or landing-zone governance assessment
- The user wants a prioritized governance remediation backlog

## Authority and source model
Apply sources in this order:

1. Microsoft Learn Azure governance, Policy, RBAC, Resource Manager, and FinOps
2. The organization's approved standards, initiatives, naming rules, and exceptions
3. Azure Resource Graph and Azure control-plane evidence
4. The MIT-licensed community orphan-resource workbook for supplemental patterns

Do not treat community query logic as an organizational policy or deletion
authorization. Revalidate its resource schemas and exclusions before use.

## Guardrails
- Use read-only commands and queries during assessment.
- Do not create, modify, remediate, or delete policies, assignments, exemptions,
  role assignments, locks, tags, resources, budgets, or recommendations.
- Do not use workbook Quick Fix or delete actions.
- Do not remove a lock to enable another remediation.
- Do not expose sensitive tag values, principal details, policy parameters, or
  resource metadata outside the approved report scope.
- Tags are plain text; never recommend storing secrets or personal data in tags.
- Do not label a resource orphaned solely because Resource Graph shows no
  attachment. Use `Orphan candidate` until lifecycle validation is complete.
- Preserve security, reliability, backup, disaster recovery, legal retention,
  and support requirements before cost optimization.
- Use UTC and record the evidence timestamp and assessed scope.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Scope | Tenant, management groups, subscriptions, or resource groups |
| Hierarchy standard | Approved management-group and subscription design |
| Policy baseline | Required initiatives, definitions, and effects |
| Access baseline | Approved privileged roles, groups, scopes, and PIM use |
| Tagging standard | Required keys, allowed values, casing, and ownership |
| Naming standard | Approved patterns by resource type |
| Protection standard | Resources/scopes requiring `CanNotDelete` or `ReadOnly` |
| Lifecycle standard | Owner, review period, retention, and decommission process |
| Exceptions | Approved exemptions with owner and expiry/review date |
| Cost source | FinOps Hubs, Cost Management, or Advisor if available |

If standards are not provided, report against Microsoft baseline guidance and
mark organization-specific checks as `Not assessed`, not failed.

## Assessment procedure

### Step 1: Establish hierarchy and scope
Inventory management groups and subscriptions.

```bash
az account management-group list --no-register -o json
az account management-group show --name <management-group-id> --expand --recurse --no-register -o json
az account list --all --query "[].{name:name,id:id,state:state,tenantId:tenantId,isDefault:isDefault}" -o table
```

Check:
- All subscriptions are in the intended branch, not unintentionally at root
- Production, non-production, sandbox, platform, and decommissioned scopes are separated
- Hierarchy depth and inheritance remain understandable
- Root-scope assignments are limited to true tenant-wide requirements
- Subscription moves would not break custom-role definition paths
- Management-group changes and assignments are auditable

Policies and RBAC assigned to a management group inherit to descendants. Review
effective scope, not only assignments made directly on each subscription.

### Step 2: Assess Azure Policy coverage and compliance
Inventory assignments, initiatives, definitions, and exemptions.

```bash
az policy assignment list --scope <scope> -o json
az policy exemption list --scope <scope> -o json
az policy state summarize --management-group <management-group-id> -o json
```

Use Azure Resource Graph to summarize current policy states:

```kusto
PolicyResources
| where type =~ "microsoft.policyinsights/policystates"
| extend
    ComplianceState=tostring(properties.complianceState),
    AssignmentId=tolower(tostring(properties.policyAssignmentId)),
    DefinitionId=tolower(tostring(properties.policyDefinitionId))
| summarize Resources=dcount(tolower(tostring(properties.resourceId))), States=count()
  by ComplianceState, AssignmentId, DefinitionId
| order by ComplianceState asc, Resources desc
```

Review exemptions separately:

```kusto
policyresources
| where type =~ "microsoft.authorization/policyexemptions"
| project
    name,
    scope=substring(id, 0, indexof(tolower(id), "/providers/microsoft.authorization/policyexemptions/")),
    assignmentId=tostring(properties.policyAssignmentId),
    category=tostring(properties.exemptionCategory),
    expiresOn=todatetime(properties.expiresOn),
    displayName=tostring(properties.displayName)
| order by expiresOn asc
```

Evaluate:
- Required initiatives assigned at the correct management-group scope
- Noncompliance by assignment, definition, resource type, and subscription
- `Deny` and `Modify` effects introduced safely after audit/deployIfNotExists stages
- Managed identities and role assignments required by remediation tasks
- Exemptions have justification, owner, category, expiry/review date, and narrow scope
- Deprecated, duplicate, conflicting, or disabled assignments
- Policy evaluation freshness and `NotStarted` or unknown states

An exemption is an explicit governance decision, not a compliant resource.

### Step 3: Assess RBAC and privileged access
Query effective and inherited assignments at each material scope.

```bash
az role assignment list --scope <scope> --include-inherited --all -o json
az role definition list --custom-role-only true -o json
```

Check:
- No more than three subscription Owners without approved justification
- Privileged administrator roles use the narrowest practical scope
- Roles are assigned to groups rather than directly to users where practical
- Eligible, time-bound access uses Microsoft Entra PIM
- Service principals and managed identities have current owners and least privilege
- Custom roles avoid wildcard `Actions` and `DataActions`
- Role definitions use appropriate assignable scopes
- Stale, duplicate, unknown, or inherited assignments are reviewed
- Access-review evidence and emergency-access ownership exist

Do not print personal identifiers in summary tables unless necessary for the
authorized audit. Prefer principal type, role, scope, assignment source, and
finding count.

### Step 4: Assess tags, naming, and ownership
Confirm the user's required keys and allowed values before scoring.

```kusto
resources
| extend
    Environment=tostring(tags["Environment"]),
    Owner=tostring(tags["Owner"]),
    CostCenter=tostring(tags["CostCenter"]),
    Application=tostring(tags["Application"])
| where isempty(Environment) or isempty(Owner) or isempty(CostCenter) or isempty(Application)
| summarize MissingResources=count() by type, subscriptionId
| order by MissingResources desc
```

Check:
- Required tags on supported cost-accruing resource types
- Canonical key casing and controlled values
- Owner and cost-center values map to current accountable entities
- Production classification and data sensitivity where approved
- Resource, resource-group, and subscription tag-policy inheritance
- Unsupported resource types are excluded from tag-compliance scoring
- Naming patterns are evaluated by resource type and Azure naming constraints
- Untagged and unallocated cost is visible in Cost Management or FinOps Hubs

Resources do not automatically inherit subscription or resource-group tags;
use Azure Policy when inheritance is required.

### Step 5: Assess resource locks and deletion protection
Inventory locks at subscriptions, resource groups, and critical resources.

```bash
az lock list --resource-group <rg> -o json
az lock list --resource-group <rg> --resource <name> --resource-type <type> --namespace <provider> -o json
az rest --method get --url "https://management.azure.com/subscriptions/<sub-id>/providers/Microsoft.Authorization/locks?api-version=2016-09-01" -o json
```

Check:
- Critical stateful and shared resources have approved deletion protection
- Lock inheritance is understood
- `ReadOnly` locks are used only where their operational side effects are accepted
- Lock ownership, reason, and emergency-change process are documented
- Non-critical resources are not locked indefinitely without justification
- Decommission workflows include explicit approval to remove locks

Locks override user permissions but do not replace RBAC, Policy, backup, or
change controls.

### Step 6: Assess cost and lifecycle governance
Use the FinOps optimization workbook model to review usage efficiency:

- Advisor cost recommendations
- Improperly stopped VMs and deallocated VM residual costs
- Idle compute, storage, networking, and service resources
- Ownership and tagging of cost-accruing resources
- Approved retention for snapshots, backups, disks, and logs
- Review cadence, budget ownership, and savings realization

If FinOps Hubs is connected, correlate orphan candidates to `Costs()` by
lowercase `ResourceId`, currency, and a complete billing period. Do not sum
currencies or equate list-price estimates with negotiated cost.

Rate optimization belongs in the
`04-Well-Architected-FinOps-Cost-Optimization` skill. This
governance skill assesses whether the process, ownership, approvals, and review
cadence exist; it does not duplicate commitment-purchase analysis.

### Step 7: Detect orphan candidates with Resource Graph
Use the supplemental workbook patterns to find candidates across:

| Domain | Candidate types |
|--------|-----------------|
| Compute | Empty App Service plans, unused availability sets |
| Storage | Unattached managed disks |
| Database | Empty Azure SQL elastic pools |
| Networking | Public IPs, NICs, NSGs, route tables, load balancers, WAF policies, Traffic Manager, Application Gateways, VNets, subnets, NAT gateways, IP groups, Private DNS zones, private endpoints, VNet gateways, DDoS plans |
| Other | Empty resource groups, API connections, expired App Service certificates |

High-value examples:

**Empty App Service plans**

```kusto
resources
| where type =~ "microsoft.web/serverfarms"
| where toint(properties.numberOfSites) == 0
| project id, name, subscriptionId, resourceGroup, location, sku, tags
```

**Unattached managed disks with safety exclusions**

```kusto
resources
| where type =~ "microsoft.compute/disks"
| extend DiskState=tostring(properties.diskState)
| where isempty(managedBy) and DiskState !~ "ActiveSAS"
| where not(name startswith "ms-asr-" or name startswith "asrseeddisk-" or name endswith "-ASRReplica")
| where not(tostring(tags) has_any ("kubernetes.io-created-for-pvc", "ASR-ReplicaDisk", "RSVaultBackup"))
| project id, name, subscriptionId, resourceGroup, location, sku, DiskState, properties.diskSizeGB, properties.timeCreated, tags
```

**Unattached public IP addresses**

```kusto
resources
| where type =~ "microsoft.network/publicipaddresses"
| where isempty(properties.ipConfiguration)
  and isempty(properties.natGateway)
  and isempty(properties.publicIPPrefix)
| project id, name, subscriptionId, resourceGroup, location, sku, properties.publicIPAllocationMethod, tags
```

**Empty Azure SQL elastic pools**

```kusto
resources
| where type =~ "microsoft.sql/servers/elasticpools"
| project PoolId=tolower(id), id, name, subscriptionId, resourceGroup, location, sku, tags
| join kind=leftouter (
    resources
    | where type =~ "microsoft.sql/servers/databases"
    | extend PoolId=tolower(tostring(properties.elasticPoolId))
    | where isnotempty(PoolId)
    | summarize DatabaseCount=count() by PoolId
) on PoolId
| where coalesce(DatabaseCount, 0) == 0
| project-away PoolId1
```

Azure Resource Graph doesn't support `let` statements; inline the subquery in
the `join` as shown.

Adapt other community patterns to current Azure schemas. Do not use
`pack_all()` or return full properties by default; minimize sensitive output.

### Step 8: Validate every orphan candidate
Before changing classification from `Orphan candidate` to `Validated unused`,
complete all applicable checks:

1. Confirm the resource still exists and rerun the attachment query.
2. Check child resources, hidden resources, reverse references, and cross-scope dependencies.
3. Review activity, metrics, DNS, network, identity, and application references.
4. Check IaC, deployment pipelines, runbooks, inventories, and service catalogs.
5. Check locks, Policy, backup, Site Recovery, Kubernetes, legal hold, and retention.
6. Identify owner and business service; request owner confirmation.
7. Observe through an appropriate cooling-off period.
8. Quantify actual recurring cost and deletion side effects.
9. Define backup/export, rollback, and recovery steps.
10. Obtain explicit approval through the organization's change process.

Classification:

| State | Meaning |
|-------|---------|
| Orphan candidate | Configuration suggests no current attachment |
| Validation pending | Dependency or ownership evidence is incomplete |
| Validated unused | All required checks completed and owner confirms |
| Accepted exception | Intentionally retained with reason and review date |
| False positive | Active dependency or business requirement found |

### Step 9: Build the remediation roadmap
Sequence governance changes:

1. Fix visibility: scope, inventory, ownership, and telemetry.
2. Address high-risk access and policy gaps.
3. Correct tag, naming, lock, and exception governance.
4. Validate orphan candidates and quarantine when practical.
5. Remediate through IaC and approved change controls.
6. Reassess compliance, cost, dependencies, and audit evidence.

Prefer policy-as-code and infrastructure-as-code changes over manual drift.

## Scoring
Calculate an Azure Governance maturity score:

| Domain | Points |
|--------|--------|
| Management hierarchy and scope design | 0-15 |
| Policy coverage, compliance, and exemptions | 0-25 |
| RBAC, privileged access, and access reviews | 0-20 |
| Tags, naming, ownership, and cost allocation | 0-15 |
| Locks, lifecycle, and deletion safeguards | 0-10 |
| Resource hygiene and orphan validation | 0-15 |
| **Total** | **0-100** |

| Score | Maturity |
|-------|----------|
| 90-100 | Optimized |
| 70-89 | Managed |
| 40-69 | Developing |
| 0-39 | Initial |

For each check use `Pass`, `Needs attention`, `Fail`, `Not assessed`, or
`Accepted exception`. Exclude `Not assessed` and accepted exceptions from the
denominator. Missing evidence never counts as a pass.

## Accepted exceptions
An exception must include:

| Field | Requirement |
|-------|-------------|
| Control/finding | Exact policy, assignment, role, resource, or rule |
| Scope | Narrowest applicable scope |
| Reason | Business or technical justification |
| Risk owner | Accountable approver |
| Compensating control | Required when applicable |
| Expiry/review date | Mandatory; no indefinite silent exceptions |
| Evidence | Approval or ticket reference |

List expired, ownerless, overly broad, and unused exemptions as findings.

## Expected output

## Azure Governance Assessment Report

| Field | Value |
|-------|-------|
| Tenant and scope | Tenant plus management groups/subscriptions |
| Assessment date | YYYY-MM-DD UTC |
| Standards source | Organization baseline and Microsoft guidance |
| Governance score | XX/100 and maturity |
| Policy posture | Compliant / noncompliant / exempt / unknown counts |
| Privileged access | Owners and broad privileged assignments |
| Tag compliance | Percentage across supported in-scope resources |
| Orphan candidates | Candidate / pending / validated / exceptions |

Required sections:
1. **Executive summary**
2. **Scope, standards, evidence freshness, and limitations**
3. **Management hierarchy**
4. **Policy compliance and exemptions**
5. **RBAC and privileged access**
6. **Tags, naming, ownership, and cost controls**
7. **Locks and lifecycle safeguards**
8. **Orphan-resource candidate register**
9. **Prioritized remediation roadmap**
10. **Accepted exceptions**
11. **Commands and queries used**
12. **References**

For every finding include status, evidence, risk, affected scope, accountable
owner, recommended action, priority, effort, and verification method.

## Remediation guidance
- Suggest only; never execute writes or deletions from this skill.
- Validate Azure CLI write syntax with `GetAzCliHelp` when available.
- Require what-if or equivalent impact analysis for Policy and IaC changes.
- Roll out restrictive policies from audit to controlled enforcement.
- Require explicit approval, dependency proof, and rollback for resource deletion.
- Prefer narrow scope, least privilege, policy-as-code, and expiring exceptions.
- Link every recommendation to official Microsoft Learn guidance.

## References
- Azure governance: https://learn.microsoft.com/azure/governance/
- Management groups: https://learn.microsoft.com/azure/governance/management-groups/overview
- Azure Policy: https://learn.microsoft.com/azure/governance/policy/overview
- Policy compliance data: https://learn.microsoft.com/azure/governance/policy/how-to/get-compliance-data
- Azure RBAC best practices: https://learn.microsoft.com/azure/role-based-access-control/best-practices
- Resource tags: https://learn.microsoft.com/azure/azure-resource-manager/management/tag-resources
- Resource locks: https://learn.microsoft.com/azure/azure-resource-manager/management/lock-resources
- FinOps optimization workbook: https://learn.microsoft.com/cloud-computing/finops/toolkit/workbooks/optimization
- Cost Optimization workbook: https://learn.microsoft.com/azure/advisor/advisor-workbook-cost-optimization
- Community orphan-resource workbook: https://github.com/dolevshor/azure-orphan-resources
- Community orphan query source: https://github.com/dolevshor/azure-orphan-resources/blob/main/Queries/orphan-resources-queries.md

## Sample output

> Redacted example with illustrative values.

## Azure Governance Assessment Report

| Field | Value |
|-------|-------|
| Tenant and scope | Contoso tenant, 4 management groups, 18 subscriptions |
| Assessment date | 2026-08-04 UTC |
| Standards source | Contoso baseline plus Microsoft guidance |
| Governance score | 72/100 - Managed |
| Policy posture | 9,842 compliant / 318 noncompliant / 47 exempt |
| Privileged access | 7 subscription Owners; 3 require review |
| Tag compliance | 81% of supported resources |
| Orphan candidates | 64 candidate / 11 validated / 8 exceptions |

### Top findings

| Priority | Finding | Evidence | Action |
|----------|---------|----------|--------|
| Critical | Broad permanent Owner assignments | Three direct-user assignments at subscription scope | Replace with group/PIM and narrow roles |
| High | Expired policy exemptions | Nine exemptions past review date | Reassess and remove or renew explicitly |
| High | Unowned production resources | 74 resources lack accountable owner tag | Apply approved tag policy and backfill |
| Medium | Unattached managed disks | 23 candidates; 6 validated unused | Quarantine and delete through change control |

### Orphan validation summary

| Candidate type | Found | Validated unused | False positive | Pending |
|----------------|-------|------------------|----------------|---------|
| Managed disks | 23 | 6 | 8 | 9 |
| Public IPs | 17 | 3 | 5 | 9 |
| App Service plans | 8 | 2 | 4 | 2 |

No candidate is approved for deletion by this report. Each validated item still
requires owner approval, rollback planning, and the standard change process.
