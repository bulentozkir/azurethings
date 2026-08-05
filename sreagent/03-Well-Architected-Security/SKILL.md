---
name: well-architected-security
description: >
  Run an Azure Well-Architected Security review using the supplied Security
  Workbook V2.3 and Network Security Workbook checks. Use for Zero Trust,
  Defender for Cloud, Secure Score, regulatory compliance, security alerts,
  Azure Policy, network segmentation, public exposure, PaaS firewalls, private
  endpoints, WAF, DDoS, NSGs, encryption, secrets, testing, and incident response.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Well-Architected Security Review

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Assess whether an Azure workload protects confidentiality, integrity, and
availability through a Zero Trust security model. Combine the current Microsoft
Well-Architected Security checklist with control-plane evidence derived from:

- `Security_WorkbookV2.3.json`
- `[Optional] Network Security Workbook.json` (internal change log v1.6)

The workbooks provide broad inventory and posture visibility. They do not prove
end-to-end workload security and must be supplemented with threat modeling,
identity, data, application, testing, and incident-response evidence.

## When to use this skill
- The user requests an Azure Well-Architected Security review
- The user asks for Defender for Cloud, Secure Score, or compliance analysis
- The user wants network security and public exposure reviewed
- The user needs a Zero Trust assessment before production launch
- The user wants security risks prioritized across an Azure workload
- The user requests a recurring security posture review

## Workbook knowledge and limitations

### Security Workbook V2.3 coverage
- Defender for Cloud plan/tier visibility
- Unhealthy Defender recommendations by subscription, resource group, or tag
- Regulatory standards, controls, and assessments
- Active Defender for Cloud alerts
- Secure Score by subscription and related security assessments

### Network Security Workbook coverage
- Azure Policy assignments and noncompliance
- Defender recommendations
- PaaS public access, service firewalls, VNet rules, and private endpoints
- Storage HTTPS, public blob access, and shared-key configuration
- SQL, MySQL, PostgreSQL, MariaDB, App Service, AKS, Key Vault, and Event Hubs
- DDoS, Front Door/App Gateway WAF, Azure Firewall, firewall policy, and NSGs
- Public IPs, DNAT, VMs with public IPs, load balancers, and edge routing
- Virtual WAN, VPN, ExpressRoute, Traffic Manager, NAT Gateway, and Front Door
- NICs, IP forwarding, peerings, DNS, route tables, subnets, private links,
  Bastion, Private DNS Resolver, Route Server, and flow-log configuration

### Limitations
- Most workbook data comes from Azure Resource Graph and represents current ARM
  configuration, not runtime traffic or exploitability.
- Public access, a missing NSG, or a firewall rule is context, not automatically
  a security failure. Validate threat path and compensating controls.
- ARM endpoint queries embedded in the workbook can use preview or older API
  versions. Prefer current CLI/Resource Graph schemas during assessment.
- The network workbook describes itself as a community artifact provided as-is.
- NSG flow-log checks require current interpretation because migration to
  virtual network flow logs can be applicable.
- Workbook output can contain public IPs, alerts, resource IDs, and sensitive
  architecture metadata. Minimize and protect exported evidence.

## Guardrails
- Use read-only Azure CLI, Resource Graph, KQL, metrics, and log queries.
- Do not change Defender plans, Policy, network rules, firewalls, NSGs, routes,
  public access, private endpoints, identities, encryption, keys, or alerts.
- Do not execute workbook links, ARM actions, or remediation buttons.
- Do not retrieve or display secrets, tokens, connection strings, packet
  payloads, full alert extended properties, or sensitive regulatory evidence.
- Do not test an exposed endpoint, scan ports, exploit a weakness, or change
  traffic without explicit authorization and an approved test plan.
- Do not treat Defender Secure Score as the workload WAF Security score.
- Separate facts, attack-path inferences, risks, and accepted business decisions.
- Use UTC and record scope, query time, workbook version, and evidence freshness.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Workload scope | Tenant, subscriptions, resource groups, resources, environment |
| Critical assets | Entry points, identities, data stores, control planes, secrets |
| Data classification | Sensitivity, residency, retention, and compliance |
| Threat model | Actors, trust boundaries, abuse cases, and attack paths |
| Security baseline | Policies, standards, Defender plans, and required controls |
| Network design | Ingress, egress, east-west, on-premises, DNS, and private access |
| Identity model | Human, workload, break-glass, privileged, and external identities |
| Operations | SIEM/SOAR, alerts, SecOps ownership, runbooks, and incidents |
| Testing | SDL, code/dependency/IaC scans, penetration tests, and control tests |
| Exceptions | Owner, reason, compensating control, and expiry/review date |

If these artifacts are missing, continue with workbook checks but classify
manual controls as `Not assessed`.

## Assessment procedure

### Step 1: Define security context and trust boundaries
Document:

1. Critical user and system flows
2. Internet, partner, on-premises, administrator, and workload entry points
3. Identity, network, application, data, and management-plane trust boundaries
4. Data classification and residency for each flow
5. Threat actors, likely abuse cases, and blast radius
6. Security responsibilities shared with platform teams and Microsoft

Use Zero Trust principles: verify explicitly, use least privilege, and assume
breach.

### Step 2: Map workbook evidence to WAF SE:01-SE:12

| WAF control | Workbook coverage | Required supplement |
|-------------|-------------------|---------------------|
| SE:01 Security baseline | Strong: Policy, Defender, Secure Score, compliance | Organization baseline, ownership, review cadence |
| SE:02 Secure development lifecycle | None | SDL, threat modeling, code/dependency/IaC/container scanning |
| SE:03 Data classification | None | Classification, labels, retention, handling, data flow |
| SE:04 Segmentation | Partial: VNets, subnets, peerings, resource organization | Identity and responsibility segmentation, trust-boundary intent |
| SE:05 Identity and access | Limited | Entra ID, PIM, RBAC, managed identity, conditional access, legacy auth |
| SE:06 Networking | Strong: ingress, egress, east-west, edge, PaaS exposure | Runtime traffic, business need, effective paths, compensating controls |
| SE:07 Encryption | Limited: HTTPS and selected service settings | At-rest/in-transit scope, keys, certificates, confidential computing |
| SE:08 Resource hardening | Partial: Defender and service configuration | OS/runtime/container/app hardening and patch lifecycle |
| SE:09 Application secrets | Partial: Key Vault network posture | Secret inventory, identity-based access, rotation, emergency process |
| SE:10 Threat monitoring | Strong: Defender alerts/plans and flow telemetry | SIEM integration, alert quality, ownership, response evidence |
| SE:11 Security testing | None | Preventive, adversarial, detection, and recovery testing |
| SE:12 Incident response | Limited: active alerts | Roles, escalation, containment, communications, exercises, lessons |

Workbook coverage never earns a pass without current workload evidence.

### Step 3: Assess Defender for Cloud posture

**Defender plan coverage**

```kusto
securityresources
| where type =~ "microsoft.security/pricings"
| extend Plan=name, Tier=tostring(properties.pricingTier), SubPlan=tostring(properties.subPlan)
| project subscriptionId, Plan, Tier, SubPlan
| order by subscriptionId asc, Plan asc
```

Do not count enabled plans only. Compare each applicable resource type with the
approved Defender coverage baseline and explain intentional exclusions.

**Secure Score by subscription**

```kusto
securityresources
| where type =~ "microsoft.security/securescores"
| where properties.environment =~ "Azure"
| extend Current=todouble(properties.score.current), Maximum=todouble(properties.score.max)
| extend SecureScorePct=round(100.0 * Current / Maximum, 1)
| project subscriptionId, SecureScorePct, Current, Maximum
| order by SecureScorePct asc
```

Report individual subscription scores and controls. Do not average scores across
subscriptions as the WAF Security result.

**Unhealthy recommendations**

```kusto
securityresources
| where type =~ "microsoft.security/assessments"
| extend
    Status=tostring(properties.status.code),
    Recommendation=tostring(properties.displayName),
    Severity=tostring(properties.metadata.severity),
    ResourceId=tolower(tostring(properties.resourceDetails.Id))
| where Status =~ "Unhealthy" and isnotempty(Severity)
| project subscriptionId, resourceGroup, ResourceId, Recommendation, Severity
| order by Severity asc
```

Correlate duplicates, exemptions, resource ownership, and workload relevance.

**Active alert summary**

```kusto
securityresources
| where type =~ "microsoft.security/alerts"
   or type =~ "microsoft.security/locations/alerts"
| where tostring(properties.Status) =~ "Active"
| extend Severity=tostring(properties.Severity), AlertType=tostring(properties.AlertType)
| summarize Alerts=count(), FirstSeen=min(todatetime(properties.TimeGeneratedUtc)), LastSeen=max(todatetime(properties.TimeGeneratedUtc))
  by subscriptionId, Severity, AlertType
| order by Alerts desc
```

Do not include `ExtendedProperties` in the report. Active alerts require SecOps
handling and are not merely posture findings.

### Step 4: Assess regulatory compliance and Azure Policy
Use Defender regulatory resources to summarize standards, controls, passed,
failed, skipped, and unsupported assessments. Confirm each selected standard is
applicable to the workload and that evidence freshness is acceptable.

Use Policy Resources for effective assignments and noncompliance:

```kusto
PolicyResources
| where type =~ "microsoft.policyinsights/policystates"
| extend
    ComplianceState=tostring(properties.complianceState),
    AssignmentId=tolower(tostring(properties.policyAssignmentId)),
    DefinitionId=tolower(tostring(properties.policyDefinitionId)),
    ResourceId=tolower(tostring(properties.resourceId))
| summarize Resources=dcount(ResourceId), Results=count()
  by ComplianceState, AssignmentId, DefinitionId
| order by ComplianceState asc, Resources desc
```

Review policy exemptions, skipped/unsupported controls, conflicting
assignments, remediation identity, enforcement mode, and scope inheritance.
Policy compliance is not evidence that application code or runtime behavior is
secure.

### Step 5: Assess PaaS network exposure and hardening
Use service-specific workbook queries and current schemas to inspect:

| Service | Evidence |
|---------|----------|
| SQL/MySQL/PostgreSQL/MariaDB | Public network access, firewall rules, VNet rules, private endpoints |
| Storage | HTTPS-only, public blob access, shared key, default action, IP/VNet rules, private endpoints |
| App Service | HTTPS-only, private endpoints, VNet integration, access restrictions |
| Key Vault | Public access, firewall default, bypass, IP/VNet rules, private endpoints, RBAC/access model |
| Event Hubs | Public access, network rules, private endpoints |
| AKS | API exposure, authorized ranges/private cluster, outbound IPs, network policy, workload identity |

For each publicly reachable service:
1. Confirm business need and data classification.
2. Determine effective source restrictions and identity requirements.
3. Check edge protection, TLS, authentication, logging, and alerting.
4. Identify whether private access is feasible and operationally supported.
5. Record compensating controls and residual risk.

`PublicNetworkAccess=Enabled` is not automatically a fail; unrestricted,
unnecessary, weakly authenticated exposure without compensating controls is.

### Step 6: Assess perimeter and external networking
Review:

- DDoS plan association and workload risk
- Front Door and Application Gateway WAF mode, policy association, and coverage
- Azure Firewall deployment, policy tier, threat intelligence, and DNAT
- Public IP inventory, ownership, SKU, and attachment
- VMs with public IPs and effective NSGs
- Internet-facing load balancer, Application Gateway, and Front Door rules
- VPN, ExpressRoute, Virtual WAN, Traffic Manager, NAT, and routing intent
- TLS termination, certificate lifecycle, origin exposure, and bypass paths

Do not infer an attack path from a public IP alone. Correlate listeners, rules,
routes, NSGs, firewalls, application authentication, and resource state.

### Step 7: Assess internal segmentation and traffic control
Review:

- NSG association and effective inbound/outbound rules
- Subnets without NSGs in the context of centralized controls
- Broad source/destination prefixes, protocols, ports, and priority
- Route tables, next hops, forced tunneling, asymmetric paths, and bypass
- VNet peering flags, transit, forwarding, and segmentation boundaries
- NIC public IPs and IP forwarding
- DNS servers, private DNS links, resolvers, and exfiltration paths
- Private endpoints, connection state, DNS resolution, and approval
- Bastion and administrative access paths
- Route Server, NAT Gateway, and shared hub dependencies
- Network flow logging, retention, analytics, and SecOps use

The attached workbook checks NSG flow logs. Validate whether virtual network flow
logs are the current target and plan migration where required.

### Step 8: Complete manual WAF controls
Require explicit evidence for workbook gaps:

| Control | Manual evidence |
|---------|-----------------|
| SE:02 | Security requirements, threat models, coding standards, review gates, SAST/DAST/SCA/IaC/container scans, supply-chain controls |
| SE:03 | Data inventory, classification, labels, residency, minimization, retention, deletion, and handling |
| SE:05 | Least privilege, PIM, conditional access, managed identity, credentialless access, break-glass, access reviews, audit |
| SE:07 | Encryption in transit/at rest/in use as required, key ownership, CMK rationale, rotation, certificate lifecycle |
| SE:08 | Baselines, patching, image provenance, endpoint protection, runtime hardening, unnecessary feature removal |
| SE:09 | Key Vault/managed HSM usage, secretless design, scoped access, rotation, emergency revocation, audit |
| SE:11 | Unit/security tests, attack simulation, penetration testing, control validation, detection testing, remediation retest |
| SE:12 | Incident roles, triage, containment, evidence, communications, legal/regulatory handling, exercises, post-incident learning |

### Step 9: Validate and prioritize findings
For every candidate:

1. Confirm current resource state and exact workload scope.
2. Identify asset, data classification, exposure, identity, and trust boundary.
3. Build the credible attack or misuse path.
4. Identify preventive, detective, and recovery controls.
5. Check policy, Defender, logs, incidents, and test evidence.
6. Record contradicting evidence and accepted business requirements.
7. Assign WAF code, risk, owner, and verification method.

Priority combines:

| Factor | Weight |
|--------|--------|
| Business and data impact | 25% |
| Exposure and attack-path feasibility | 25% |
| Privilege and blast radius | 20% |
| Control weakness and exploit preconditions | 15% |
| Detection and response weakness | 15% |

Do not use Defender severity alone as final workload priority.

## Scoring
Score each applicable `SE:01` through `SE:12` control from 0 to 5:

| Score | Meaning |
|-------|---------|
| 5 | Implemented, continuously monitored, and tested |
| 3 | Partially implemented or evidence has material gaps |
| 1 | Ad hoc or design-only with little operating evidence |
| 0 | Absent, failed, or not assessed because evidence is missing |
| N/A | Demonstrably not applicable; excluded from denominator |

Overall WAF Security score:

`sum(control scores) / (applicable controls * 5) * 100`

| Score | Maturity |
|-------|----------|
| 90-100 | Optimized |
| 70-89 | Managed |
| 40-69 | Developing |
| 0-39 | Initial |

Report separately:
- Defender Secure Score by subscription
- Regulatory compliance by standard
- Policy compliance
- Active security alerts
- Workbook query coverage and manual-control coverage

## Accepted exceptions
An accepted security exception must include:

| Field | Requirement |
|-------|-------------|
| Control/finding | WAF code and exact resource/flow |
| Reason | Business and technical justification |
| Threat and impact | Residual attack path and consequence |
| Compensating controls | Preventive, detective, and recovery controls |
| Risk owner | Accountable approver |
| Expiry/review date | Mandatory |
| Evidence | Approval, test, or ticket reference |

List exceptions separately. Reopen expired, ownerless, overly broad, or changed
exceptions.

## Expected output

## Azure Well-Architected Security Review Report

| Field | Value |
|-------|-------|
| Workload and environment | Name plus production/shared scope |
| Subscriptions/resource groups | Assessed scope |
| Assessment date | YYYY-MM-DD UTC |
| Security classification | Highest in-scope classification |
| WAF Security score | XX/100 and maturity |
| Defender Secure Score | Per subscription, separate from WAF |
| Findings | Critical / High / Medium / Low |
| Active alerts | Count by severity |
| Accepted exceptions | Count and nearest review date |

Required sections:
1. **Executive summary**
2. **Scope, threat model, classifications, evidence, and limitations**
3. **SE:01-SE:12 scorecard**
4. **Defender posture, Secure Score, compliance, and alerts**
5. **Identity and access**
6. **Network exposure and segmentation**
7. **Data, encryption, secrets, and resource hardening**
8. **SDL, testing, monitoring, and incident response**
9. **Prioritized remediation roadmap**
10. **Accepted exceptions**
11. **Commands, queries, workbook versions, and references**

Every finding must include WAF code, affected flow/resource, evidence, credible
threat path, impact, existing controls, priority, recommendation, tradeoffs,
owner, effort, verification, and official documentation.

## Remediation guidance
- Suggest only; never execute security changes or tests from this skill.
- Validate Azure CLI write syntax with `GetAzCliHelp` when available.
- Use deployment what-if/preview and staged rollout for infrastructure controls.
- Avoid lockout: define break-glass, rollback, DNS, routing, and monitoring first.
- Test network and identity changes from all required paths before enforcement.
- Route active alerts to SecOps rather than treating them as backlog items.
- Recalculate score only after remediation and validation evidence exists.

## References
- WAF Security principles: https://learn.microsoft.com/azure/well-architected/security/principles
- WAF Security checklist: https://learn.microsoft.com/azure/well-architected/security/checklist
- Zero Trust network segmentation: https://learn.microsoft.com/security/zero-trust/azure-networking-segmentation
- Azure network security best practices: https://learn.microsoft.com/azure/security/fundamentals/network-best-practices
- Defender for Cloud Secure Score: https://learn.microsoft.com/azure/defender-for-cloud/secure-score-security-controls
- Azure Policy compliance: https://learn.microsoft.com/azure/governance/policy/how-to/get-compliance-data
- Azure RBAC best practices: https://learn.microsoft.com/azure/role-based-access-control/best-practices
- Migrate NSG to VNet flow logs: https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
- Attached source: `Security_WorkbookV2.3.json`
- Attached source: `[Optional] Network Security Workbook.json`

## Sample output

> Redacted example with illustrative values.

## Azure Well-Architected Security Review Report

| Field | Value |
|-------|-------|
| Workload and environment | Payments API - Production |
| Subscriptions/resource groups | 2 subscriptions, 9 resource groups |
| Assessment date | 2026-08-04 UTC |
| Security classification | Confidential |
| WAF Security score | 63/100 - Developing |
| Defender Secure Score | Prod 78%; Shared Services 71% |
| Findings | 2 Critical / 6 High / 9 Medium / 4 Low |
| Active alerts | 1 High / 3 Medium |
| Accepted exceptions | 3; nearest review 2026-09-15 |

### Top findings

| Priority | WAF | Evidence | Recommendation |
|----------|-----|----------|----------------|
| Critical | SE:05 | Permanent broad privileged assignment controls production and shared networking | Replace with group/PIM and narrowly scoped roles |
| Critical | SE:09 | Application uses long-lived shared key stored outside approved secret store | Migrate to managed identity and revoke through an approved rotation |
| High | SE:06 | Public database endpoint permits broad network source ranges | Restrict access and validate private connectivity plus DNS |
| High | SE:12 | High Defender alert has no confirmed owner or containment record | Route to SecOps and execute the incident runbook |

### Workbook coverage

| Evidence source | Checks | Confirmed findings | Pending |
|-----------------|--------|--------------------|---------|
| Security Workbook V2.3 | Defender, compliance, alerts, Secure Score | 18 | 4 |
| Network Security Workbook | Policy, PaaS exposure, perimeter, internal network | 27 | 11 |
| Manual WAF review | SDL, data, IAM, encryption, secrets, tests, response | 12 | 5 |

No remediation, traffic test, or exploit validation was executed by this review.
