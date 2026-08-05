---
name: azure-ai-foundry
description: >
  Assess and troubleshoot an Azure AI and Microsoft Foundry estate using the
  ai-foundry-issues-workbook. Use for Azure OpenAI and Foundry accounts,
  Foundry projects, AI Hub and AI Project workspaces, model deployments, model
  lifecycle and retirement, security posture, network exposure, guardrails,
  monitoring, quota, throttling, cost, Advisor, Resource Health, and service
  retirement readiness.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure AI Foundry

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Perform a read-only, fleet-wide assessment of:

- Azure OpenAI and Microsoft Foundry accounts
- Microsoft Foundry projects
- Classic AI Hub, AI Project, Azure ML, and feature-store workspaces
- Model deployments and regional model lifecycle
- Identity, encryption, network, and provisioning posture
- Monitoring, quota, throttling, usage, and cost signals
- Responsible AI guardrails and agent governance
- Azure Advisor, Resource Health, model retirement, and service retirement

Use `ai-foundry-issues-workbook.json` as the inventory and issue model, then
validate findings with current Microsoft documentation and runtime evidence.

## When to use this skill
- The user asks for an Azure AI Foundry estate review
- Model deployments fail, throttle, degrade, or approach retirement
- Azure OpenAI or Foundry security and network posture must be assessed
- Foundry projects, classic hubs, or AI Project workspaces need governance review
- The user needs quota, PTU utilization, token, latency, or availability analysis
- The user wants AI service and model retirement readiness
- Advisor recommendations or Resource Health events affect AI resources

## Workbook source and scope
The two discovered workbook copies are byte-identical. Use:

`ai-foundry-workbook/ai-foundry-issues-workbook.json`

The workbook intentionally combines:

| Source | Use |
|--------|-----|
| Azure Resource Graph | Accounts, projects, workspaces, Advisor, health, and Service Health |
| ARM account deployments endpoint | Actual model deployments for one selected account |
| ARM regional models endpoint | Live model lifecycle and retirement dates |
| Advisor metadata endpoint | Service Upgrade and Retirement catalog |

Record the workbook hash, assessment date, selected subscriptions, resource
groups, account, account region, and account kind for reproducibility.

## Important data limitations
- `Microsoft.CognitiveServices/accounts` is visible in Resource Graph.
- `Microsoft.CognitiveServices/accounts/projects` is visible in Resource Graph.
- `Microsoft.MachineLearningServices/workspaces` is visible in Resource Graph.
- `Microsoft.CognitiveServices/accounts/deployments` is not reliably indexed in
  Resource Graph. Read deployments from the selected account's ARM endpoint.
- The deployments endpoint accepts one account resource path at a time. Do not
  concatenate multiple account IDs.
- The regional model catalog returns rows by account kind. Filter by the selected
  account kind to avoid duplicate model/version rows.
- Service Health and Advisor retirement sources are independent. Do not merge
  them without a supported tracking-ID or recommendation mapping.
- Advisor metadata is a planning catalog. It doesn't prove that a feature is
  deployed in the selected scope.
- Blank Resource Graph values can mean not configured, but always verify the
  current API schema before making a high-impact conclusion.

## Guardrails
- Use read-only Azure CLI, Resource Graph, ARM GET, Azure Monitor, and KQL.
- Do not deploy or delete models, change upgrade policy, quota, capacity, network,
  identity, keys, guardrails, diagnostic settings, or projects.
- Do not retrieve or expose prompts, completions, agent conversations, secrets,
  connection strings, API keys, evaluation data, or customer content.
- Treat RequestResponse and Trace logs as sensitive. Query only metadata needed
  for diagnosis and redact payload-bearing fields.
- Do not call an account insecure merely because it uses Microsoft-managed keys
  or public access. Compare configuration with data classification and baseline.
- Do not call a deployment unfiltered solely because `raiPolicyName` is empty.
  Validate the effective default or custom guardrail configuration.
- Preview models and features have no production SLA unless explicitly stated.
- Use UTC and distinguish observed facts, workbook candidates, and conclusions.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Scope | Subscriptions, resource groups, accounts, projects, and workspaces |
| Workloads | Applications, agents, critical flows, owners, and environments |
| Data | Classification, residency, retention, and prompt/completion handling |
| Models | Deployment name, model, version, type, SKU, capacity, and upgrade policy |
| Targets | Availability, latency, quality, safety, throughput, RTO, and RPO |
| Security baseline | Identity, network, encryption, secrets, and guardrails |
| Telemetry | Azure Monitor metrics, diagnostic settings, logs, and cost access |
| Lifecycle | Model and Azure service retirement deadlines |
| Exceptions | Owner, reason, compensating control, and expiry/review date |

If workload context is absent, report configuration posture but don't infer
business impact or final risk.

## Assessment procedure

### Step 1: Inventory the AI estate
Query all in-scope accounts:

```kusto
resources
| where type =~ "microsoft.cognitiveservices/accounts"
| project id, name, subscriptionId, resourceGroup, location, kind, sku,
          identity, properties
```

Classify account kinds:

| Kind | Workbook label |
|------|----------------|
| `OpenAI` | Azure OpenAI |
| `AIServices` | Microsoft Foundry |
| `CognitiveServices` | Cognitive Services multi-service |
| Other | Individual Foundry Tools service |

Inventory Foundry projects:

```kusto
resources
| where type =~ "microsoft.cognitiveservices/accounts/projects"
| extend ParentAccountId=tolower(substring(id, 0, indexof(id, "/projects/")))
| project id, name, subscriptionId, resourceGroup, location, identity,
          ParentAccountId, properties
```

Inventory classic workspaces:

```kusto
resources
| where type =~ "microsoft.machinelearningservices/workspaces"
| project id, name, subscriptionId, resourceGroup, location, kind, identity,
          properties
```

Include connected Storage, Key Vault, AI Search, networking, and monitoring
resources in the workload boundary. They have separate governance controls.

### Step 2: Assess account identity, encryption, and provisioning
Evaluate these workbook candidates:

| Candidate | Validation |
|-----------|------------|
| Local/API key authentication enabled | Confirm `disableLocalAuth`, workload compatibility, and Entra migration path |
| No managed identity | Confirm whether the account requires service-to-service access |
| No custom subdomain | Confirm whether Entra authentication for the used APIs requires it |
| Microsoft-managed encryption | Compare with approved CMK and compliance requirements |
| Provisioning not succeeded | Confirm current state, activity log, and operational impact |

Prefer managed identity and Entra ID over stored keys. Review RBAC separately at
the Foundry resource, project, and connected-resource scopes.

Foundry projects inherit parent account authentication and network posture but
can have their own managed identities and RBAC scope. Validate both levels.

### Step 3: Assess network posture
Evaluate:

- `publicNetworkAccess`
- `networkAcls.defaultAction`
- IP and VNet rule counts
- private endpoint connections and approval state
- `restrictOutboundNetworkAccess`
- managed VNet or customer-managed VNet isolation
- DNS resolution for private endpoints
- agent outbound access to tools and connected resources

The workbook flags:

- Public network access with no private endpoint
- Public access with network default action other than `Deny`
- Unrestricted outbound access for model-hosting accounts
- Managed VNet isolation disabled for classic workspaces

Validate effective exposure, identity, WAF/API gateway controls, required egress,
and operational support before assigning risk.

### Step 4: Assess classic hubs and workspaces
Review workbook candidates:

| Candidate | Evidence |
|-----------|----------|
| Public access without private link | Public access, private link count, effective paths |
| Managed VNet isolation disabled | `properties.managedNetwork.isolationMode` |
| Datastores use access keys | `properties.systemDatastoresAuthMode` |
| No CMK | Approved encryption baseline and workload classification |
| No managed identity | Identity type and connected-resource access pattern |
| Soft delete disabled | Recovery and retention requirements |
| V1 legacy mode | Migration/support plan |
| AI Project not linked to hub | `hubResourceId` and intended architecture |
| Failed provisioning | Provisioning state and activity log |

Do not use the workbook's finding count as final risk. It is a triage score:
Critical >=6, High 4-5, Medium 2-3, Low 1, Healthy 0.

### Step 5: Read actual model deployments
For one selected OpenAI or AIServices account:

```http
GET {account-resource-id}/deployments?api-version=2024-10-01
```

Capture:

- Deployment and resource ID
- Model name, version, and format
- SKU and capacity
- `versionUpgradeOption`
- `raiPolicyName`
- Provisioning state

Interpret upgrade policy:

| Policy | Meaning |
|--------|---------|
| `NoAutoUpgrade` | Manual migration required; deployment can stop at retirement |
| `OnceCurrentVersionExpired` | Standard deployment upgrades at expiry |
| `OnceNewDefaultVersionAvailable` | Standard deployment follows new default |

Provisioned deployments require explicit migration planning and aren't
automatically upgraded by the platform lifecycle process.

An empty deployment list can be valid for AI Services accounts used only for
Speech, Vision, Language, or Document Intelligence.

### Step 6: Correlate deployments with model lifecycle
Read the model catalog for the selected subscription, region, and account kind:

```http
GET /subscriptions/{subscription-id}/providers/Microsoft.CognitiveServices/locations/{region}/models?api-version=2024-10-01
```

Match each deployment by model name and version. Capture:

- `model.lifecycleStatus`
- `model.deprecation.inference`
- `model.deprecation.fineTune`
- per-SKU retirement date when available
- maximum capacity and regional availability

API lifecycle terminology differs from portal terminology:

| API value | Operational meaning |
|-----------|---------------------|
| `Preview` | Preview; not recommended for production |
| `GenerallyAvailable` | GA |
| `Deprecating` | Deprecated; migration must be planned |
| `Deprecated` | Retired; inference should return `410 Gone` |

Prioritize `NoAutoUpgrade`, provisioned, batch, preview, fine-tuned, and
contract-changing replacement migrations. Retirement dates aren't extendable.

### Step 7: Assess guardrails and responsible AI
For each deployment and agent:

- Confirm effective default or custom content filters/guardrails
- Review input, output, tool-call, and tool-response protection where applicable
- Confirm jailbreak, harmful content, groundedness, and data-leakage evaluation
- Verify human oversight and approval for high-impact actions
- Restrict tools, identities, data sources, and network destinations
- Review evaluation evidence before model/version migration
- Confirm incident, abuse-monitoring, and emergency disable processes

An empty `raiPolicyName` requires investigation. It isn't sufficient evidence
that no platform default protection exists.

### Step 8: Assess monitoring and diagnostic logging
Metrics are available automatically. Review by deployment, model, version,
region, operation, stream type, and status code:

- `ModelAvailabilityRate`
- `ModelRequests`
- `TimeToResponse`
- `NormalizedTimeBetweenTokens`
- `InputTokens`, `OutputTokens`, and `TotalTokens`
- `TokensCacheMatchRate`
- `ProvisionedUtilization`
- `ProvisionedConsumedTokens`

Inspect diagnostic routing:

```bash
az monitor diagnostic-settings list --resource <foundry-resource-id> -o json
```

Validate required categories such as Audit, RequestResponse, Azure OpenAI usage,
and AllMetrics. Log ingestion can be delayed; don't declare a gap immediately
after configuration.

Use metadata-only latency and error analysis:

```kusto
AzureDiagnostics
| where ResourceProvider =~ "MICROSOFT.COGNITIVESERVICES"
| where _ResourceId =~ "<resource-id>"
| where Category == "RequestResponse"
| summarize Requests=count(), P50=percentile(DurationMs, 50),
            P95=percentile(DurationMs, 95), P99=percentile(DurationMs, 99)
  by ResultSignature, OperationName
| order by Requests desc
```

Do not project prompt, response, URI query, or sensitive custom dimensions.

### Step 9: Assess quota, throttling, capacity, and cost
Use the least-privileged Cognitive Services Usages Reader role for quota review.

For 429 errors:
1. Identify deployment, model, SKU, region, and error subtype.
2. Check request/token limits and retry behavior.
3. Check `ProvisionedUtilization`; at or above 100% can cause throttling.
4. Separate quota exhaustion, rate limiting, temporary capacity, and abuse limits.
5. Validate exponential backoff and load shaping before requesting more quota.

Assess:
- Quota allocation versus used capacity
- Regional/model availability for planned migrations
- PTU utilization, reservation commitment, and failover capacity
- Pay-per-token input/output usage and cache effectiveness
- Orphaned or idle deployments
- Cost by deployment after the documented Cost Management billing delay

Do not mix token consumption, PTU capacity, and billed cost as equivalent units.

### Step 10: Assess service retirement, Advisor, and health
Keep these sources separate:

1. AI-related Service Health retirement advisories, including past-due items
2. Advisor Service Upgrade and Retirement metadata and affected resources
3. Model lifecycle from the regional Models API
4. General Advisor recommendations for accounts and workspaces
5. Resource Health availability state

Use tracking IDs to correlate Service Health with Advisor when supported.
Resource-level retirement coverage isn't comprehensive; missing rows require
code, IaC, SDK, API, and owner validation.

### Step 11: Validate findings and prioritize
For each workbook candidate:

1. Confirm current control-plane state and API schema.
2. Identify workload, data classification, model, agent, and critical flow.
3. Add runtime metrics, logs, quota, cost, health, and incident evidence.
4. Test at least one alternative explanation.
5. Define impact, owner, target state, and verification.

Final priority combines:

| Factor | Weight |
|--------|--------|
| Data, security, and responsible-AI impact | 25% |
| Production availability and model lifecycle risk | 25% |
| Exposure, privilege, and blast radius | 20% |
| Quota, capacity, and performance impact | 15% |
| Detection, migration, and operational readiness | 15% |

## Scoring
Calculate an Azure AI Foundry posture score:

| Domain | Points |
|--------|--------|
| Estate inventory and project governance | 0-10 |
| Identity, encryption, secrets, and RBAC | 0-15 |
| Network isolation and connected resources | 0-15 |
| Model deployment and lifecycle readiness | 0-20 |
| Responsible AI, guardrails, and agent governance | 0-15 |
| Monitoring, quota, performance, and cost | 0-15 |
| Advisor, health, and service retirement readiness | 0-10 |
| **Total** | **0-100** |

| Score | Maturity |
|-------|----------|
| 90-100 | Optimized |
| 70-89 | Managed |
| 40-69 | Developing |
| 0-39 | Initial |

Missing evidence earns zero points and never counts as healthy.

## Accepted exceptions
Each exception must include:

| Field | Requirement |
|-------|-------------|
| Finding | Exact account, project, workspace, model, or agent |
| Reason | Business and technical justification |
| Data/AI risk | Security, safety, quality, privacy, and availability impact |
| Compensating control | Preventive, detective, and recovery controls |
| Owner | Accountable approver |
| Expiry/review date | Mandatory |
| Evidence | Approval and test reference |

Model retirement dates cannot be extended by an exception.

## Expected output

## Azure AI Foundry Assessment Report

| Field | Value |
|-------|-------|
| Scope | Subscriptions, resource groups, accounts, and workspaces |
| Assessment date | YYYY-MM-DD UTC |
| AI estate | Account, project, workspace, and deployment counts |
| Model lifecycle | Retiring / retired / preview / GA deployment counts |
| Critical findings | Count |
| 429 or capacity risks | Count |
| Retirement gaps | Model and Azure service counts |
| Overall score | XX/100 and maturity |

Required sections:
1. **Executive summary**
2. **Scope, data sources, workbook hash, and limitations**
3. **AI estate and project hierarchy**
4. **Account and workspace posture**
5. **Model deployment and retirement matrix**
6. **Guardrails, agents, and responsible AI**
7. **Monitoring, quota, performance, and cost**
8. **Advisor, Resource Health, and service retirements**
9. **Prioritized remediation roadmap**
10. **Accepted exceptions**
11. **Commands, queries, APIs, and references**

Each finding must include source, resource/deployment, evidence, risk, priority,
owner, recommendation, effort, target date, and verification.

## Remediation guidance
- Suggest only; never execute writes from this skill.
- Validate Azure CLI write syntax with `GetAzCliHelp` when available.
- Use IaC preview/what-if and staged rollout for account/network changes.
- Use side-by-side model migration with representative evaluations where possible.
- Preserve rollback until quality, safety, latency, quota, and cost criteria pass.
- Test identity and private networking before disabling keys or public access.
- Link every recommendation to official Microsoft documentation.

## References
- Workbook source: `ai-foundry-workbook/ai-foundry-issues-workbook.json`
- Microsoft Foundry architecture: https://learn.microsoft.com/azure/foundry/concepts/architecture
- Monitor model deployments: https://learn.microsoft.com/azure/foundry/foundry-models/how-to/monitor-models
- Diagnostic logging: https://learn.microsoft.com/azure/foundry/how-to/diagnostic-logging
- Model lifecycle: https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirements
- Model versions: https://learn.microsoft.com/azure/foundry/foundry-models/concepts/model-versions
- Quota and throttling: https://learn.microsoft.com/azure/foundry/openai/how-to/quota
- Notification Center: https://learn.microsoft.com/azure/foundry/concepts/concept-notification-center
- Responsible AI: https://learn.microsoft.com/azure/foundry/responsible-use-of-ai-overview
- Service retirement guidance: https://learn.microsoft.com/azure/service-health/service-retirement-alerting-guidance

## Sample output

> Redacted example with illustrative values.

## Azure AI Foundry Assessment Report

| Field | Value |
|-------|-------|
| Scope | 4 subscriptions, 12 resource groups |
| Assessment date | 2026-08-04 UTC |
| AI estate | 18 accounts, 31 projects, 14 classic workspaces, 42 deployments |
| Model lifecycle | 8 retiring / 1 retired / 4 preview / 29 GA |
| Critical findings | 3 |
| 429 or capacity risks | 5 |
| Retirement gaps | 2 models and 1 Azure service |
| Overall score | 67/100 - Developing |

### Top findings

| Priority | Finding | Evidence | Next action |
|----------|---------|----------|-------------|
| Critical | Retired model still deployed | Catalog status `Deprecated`; deployment uses `NoAutoUpgrade` | Migrate side-by-side and validate evaluations |
| Critical | Production account permits keys and unrestricted public access | Local auth enabled, ACL default Allow, no private endpoint | Validate Entra/private path before staged restriction |
| High | Provisioned deployment near saturation | Provisioned utilization >=95% and correlated 429s | Load-shape and validate PTU capacity |
| High | Agent connected resources lack unified governance evidence | Storage, Search, and Key Vault controls assessed separately | Complete dependency security review |

Workbook finding-count severity was used only for triage; final priorities include
workload criticality, data sensitivity, runtime evidence, and model lifecycle.
