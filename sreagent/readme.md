# Azure SRE Agent Skills Pack

> Custom skills for [Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/) focused on Well-Architected reviews, governance, lifecycle readiness, monitoring, and evidence-driven troubleshooting.

> Community project: Review and adapt these skills for your organization, Azure cloud, policies, workloads, and risk requirements. They are not a substitute for Microsoft support or an approved production change process.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)

## What is this?

This pack contains 21 reusable `SKILL.md` runbooks for Azure SRE Agent. The skills combine:

- Official Microsoft Learn guidance
- Azure Well-Architected Framework recommendations
- Azure MCP and Azure Monitor diagnostic capabilities
- Azure Resource Graph, Advisor, Service Health, and Resource Health
- Application Insights APM, platform metrics, logs, and bounded data-plane queries
- Selected Azure workbooks and Microsoft community libraries

The skills are read-only by default. They gather evidence, correlate findings, score confidence or maturity, and suggest remediation without automatically changing Azure resources.

## Skills catalog

| # | Skill | Primary use | Outcome |
|---|-------|-------------|---------|
| 01 | [Well-Architected Reliability](01-Well-Architected-Reliability/SKILL.md) | APRL, Advisor Reliability workbook, SLO/RTO/RPO, failure modes, HA, DR, testing | Reliability score and action plan |
| 02 | [Well-Architected Operational Excellence](02-well-architected-operational-excellence/SKILL.md) | DevOps culture, IaC, supply chain, observability, incidents, testing, automation, safe deployments | Operational maturity roadmap |
| 03 | [Well-Architected Security](03-Well-Architected-Security/SKILL.md) | Zero Trust, Defender for Cloud, Secure Score, compliance, IAM, network and data controls | Security posture and prioritized risks |
| 04 | [Well-Architected FinOps Cost Optimization](04-Well-Architected-FinOps-Cost-Optimization/SKILL.md) | FinOps Hubs, FOCUS, rate and usage optimization, Advisor, commitments, waste | Deduplicated savings plan |
| 05 | [Well-Architected Performance Efficiency](05-well-architected-performance/SKILL.md) | Performance targets, capacity, scaling, partitioning, testing, code and data optimization | Performance maturity and experiment backlog |
| 06 | [Azure Monitor Baseline](06-Azure-Monitor-Baseline/SKILL.md) | AMBA coverage, alert drift, telemetry, action groups, Policy, thresholds, testing | Monitoring baseline assessment |
| 07 | [Azure Legacy VM](07-Azure-Legacy-VM/SKILL.md) | Previous-generation VM capacity restrictions, VMSS growth, retirements, quota, migration | VM migration readiness plan |
| 08 | [Azure AI Foundry](08-Azure-AI-Foundry/SKILL.md) | Foundry/OpenAI estate, projects, models, lifecycle, guardrails, quota, monitoring, health | AI estate posture and retirement plan |
| 09 | [.NET Core App Troubleshooting](09-dotnet-core-app-troubleshooting/SKILL.md) | App startup, HTTP errors, CPU, memory, OOM, dependencies, Application Insights | Ranked .NET root-cause analysis |
| 10 | [Azure SQL DBA Troubleshooting](10-azure-sql-dba-troubleshooting/SKILL.md) | Azure SQL performance, Query Store, waits, blocks, deadlocks, timeouts, pools | DBA diagnosis and verification plan |
| 11 | [Azure PostgreSQL DBA Troubleshooting](11-azure-postgresql-dba-troubleshooting/SKILL.md) | PostgreSQL Flexible Server CPU, memory, IO, locks, vacuum, replicas, HA | PostgreSQL root-cause analysis |
| 12 | [Azure MySQL DBA Troubleshooting](12-azure-mysql-dba-troubleshooting/SKILL.md) | MySQL Flexible Server CPU, memory, IO, queries, locks, replication, HA | MySQL root-cause analysis |
| 13 | [Azure Cosmos DB DBA Troubleshooting](13-azure-cosmosdb-dba-troubleshooting/SKILL.md) | RU, 429s, hot partitions, latency, indexing, consistency, SDK, regions | Cosmos DB root-cause analysis |
| 14 | [Azure AKS and ACR Troubleshooting](14-azure-aks-acr-troubleshooting/SKILL.md) | Cluster, nodes, pods, autoscaling, DNS, networking, image pulls, ACR | AKS/ACR incident diagnosis |
| 15 | [Azure ACA, ACI, and ACR Troubleshooting](15-azure-aca-aci-acr-troubleshooting/SKILL.md) | Revisions, replicas, ingress, KEDA, Dapr, ACI groups, image pulls | Container platform diagnosis |
| 16 | [Azure App Services Troubleshooting](16-appservices-troubleshooting/SKILL.md) | Web apps, plans, ASE, AppLens, deployments, HTTP errors, saturation, networking | App Service diagnosis |
| 17 | [Azure Functions Troubleshooting](17-functions-troubleshooting/SKILL.md) | Host, triggers, retries, scaling, storage, runtime, slots, Linux Consumption retirement | Functions diagnosis and migration readiness |
| 18 | [Azure Governance and Compliance](18-Govenance-Compliance/SKILL.md) | Management hierarchy, Policy, RBAC, tags, locks, ownership, orphan lifecycle | Governance maturity and remediation plan |
| 19 | [Azure Service Retirements](19-Azure-Service-Retirements/SKILL.md) | Service Health signals, Advisor impact, deadlines, migration and verification | Retirement action register |
| 20 | [Java App Troubleshooting](20-java-app-troubleshooting/SKILL.md) | AppLens, Application Insights APM, JVM, GC, threads, memory, dependencies | Ranked Java root-cause analysis |
| 21 | [Azure Front Door Security Troubleshooting](21-FrontDoor-Security-Troubleshooting/SKILL.md) | Front Door WAF, access, health-probe, bot, abuse, origin, and Workbook v3 evidence | Ranked security and origin diagnosis |

Each skill includes:

- Trigger-oriented metadata
- Purpose and guardrails
- Prerequisites and scope checks
- Step-by-step investigation or assessment procedure
- Confidence or maturity scoring
- Accepted-exception handling
- Required report format
- Remediation guidance
- Official references
- Redacted sample output

## Who is this for?

| Persona | Typical use |
|---------|-------------|
| SRE and platform engineers | Investigate incidents and create evidence-based action plans |
| Cloud architects | Run Well-Architected reviews and readiness assessments |
| Database administrators | Diagnose Azure SQL, PostgreSQL, MySQL, and Cosmos DB |
| Application teams | Troubleshoot .NET, Java, App Service, and Functions |
| Container platform teams | Investigate AKS, Container Apps, Container Instances, and ACR |
| Governance and security teams | Review Policy, RBAC, controls, compliance, and lifecycle risk |
| FinOps practitioners | Validate cost optimization opportunities and avoid overlapping savings |

## Prerequisites

- An Azure SRE Agent in the [Azure SRE Agent portal](https://sre.azure.com/)
- Reader access to the Azure scopes being assessed
- Log Analytics or Application Insights permissions for telemetry queries
- Service-specific read access where data-plane diagnostics are required
- Cost Management Reader for cost analysis
- Appropriate Microsoft Entra and database identities for approved read-only queries

Some investigations need additional telemetry or connectors. The skills report missing telemetry as an evidence gap rather than treating it as a healthy result.

## Mandatory MCP connectors

Every skill requires these exact Azure SRE Agent connection IDs:

| Connection ID | Transport | Configuration |
|---------------|-----------|---------------|
| `AzureMCP` | stdio | Command `npx`; arguments `-y`, `@azure/mcp@latest`, `server`, `start`; authenticate with the agent managed identity |
| `MicrosoftLearnMCP` | Streamable HTTP | Endpoint `https://learn.microsoft.com/api/mcp`; no authentication headers |

In **Builder > Connectors**, create both connections and confirm that each status is **Connected**. In **Builder > Skills**, attach `AzureMCP/*` and `MicrosoftLearnMCP/*` to every skill. The wildcard connection IDs in each `SKILL.md` keep discovered tools synchronized; verify that the combined native and MCP selection stays within the 80-tool agent limit.

Grant the Azure SRE Agent managed identity only the read roles needed by each investigation. The skills must use Azure MCP for live Azure evidence and Microsoft Learn MCP for current authoritative guidance before conclusions. If either connection is unavailable, they report a blocking evidence gap instead of relying on model memory.

## Quick start

1. Open [Azure SRE Agent](https://sre.azure.com/) and select your agent.
2. Configure the two mandatory MCP connections above.
3. Go to **Builder** and open the skill or subagent builder.
4. Create a new skill.
5. Paste the contents of the selected `SKILL.md`.
6. Attach the read-only tools referenced in its YAML front matter.
7. Save the skill and test it against a non-production or approved scope.
8. Review every recommendation before using it in a production change.

## Example prompts

```text
Run a Well-Architected Reliability review for the production workload.
Assess our AMBA alert coverage across landing-zone subscriptions.
Find Azure services and resources affected by upcoming retirements.
Why is the PostgreSQL Flexible Server CPU high?
Investigate 429 throttling and hot partitions in Cosmos DB.
Diagnose ImagePullBackOff from AKS to ACR.
Troubleshoot the failing Container Apps revision.
Why are Java request p99 and Hikari pending connections increasing?
Assess our Azure OpenAI model retirement and quota exposure.
Investigate Front Door WAF blocks, bot activity, and origin health failures.
```

Azure SRE Agent uses the skill name and description to activate the most relevant runbook.

## Safety model

The pack follows a **read, correlate, suggest** model:

1. Read Azure configuration, metrics, logs, health, and approved data-plane evidence.
2. Correlate independent sources and test competing hypotheses.
3. Separate facts, inferences, gaps, and accepted exceptions.
4. Suggest the smallest safe remediation with risk and rollback guidance.
5. Require explicit approval before any production change or intrusive diagnostic collection.

The skills do not automatically:

- Restart, stop, scale, fail over, restore, or migrate resources
- Change settings, identities, networking, policies, alerts, or throughput
- Kill database sessions or Kubernetes workloads
- Delete resources, images, data, or telemetry
- Collect heap, memory, core, or crash dumps without approval
- Reveal secrets, connection strings, credentials, or private payloads

## Customization

Before production use, customize:

- Subscription, management-group, resource-group, and tag scopes
- SLO, SLA, RTO, RPO, latency, throughput, and capacity targets
- Required governance tags and naming rules
- Alert severities and thresholds
- Approved exception format and expiry policy
- Workload ownership and escalation paths
- Data classification and retention requirements
- Remediation approval and change-management process

Keep Microsoft Learn and Azure service documentation authoritative when workbook, repository, or local guidance differs from current platform behavior.

## Suggested cadence

| Skill group | Suggested cadence |
|-------------|-------------------|
| Reliability, Security, Operational Excellence, Performance | Quarterly and before major launches |
| FinOps Cost Optimization | Monthly |
| Azure Monitor Baseline | Monthly and after monitoring changes |
| Governance and Compliance | Weekly or monthly |
| Service Retirements and Legacy VM | Weekly |
| Azure AI Foundry | Biweekly or monthly |
| Troubleshooting skills | On demand during incidents and regressions |

Azure SRE Agent can load a limited number of concurrent skills. Assign skills to focused subagents or activate only those relevant to the current task.

## Knowledge sources

These skills are grounded primarily in:

- [Azure SRE Agent documentation](https://learn.microsoft.com/azure/sre-agent/)
- [Azure Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/)
- [Azure Monitor documentation](https://learn.microsoft.com/azure/azure-monitor/)
- [Azure Advisor](https://learn.microsoft.com/azure/advisor/)
- [Azure Proactive Resiliency Library](https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/)
- [Azure Monitor Baseline Alerts](https://azure.github.io/azure-monitor-baseline-alerts/)
- [FinOps Toolkit](https://learn.microsoft.com/cloud-computing/finops/toolkit/)
- Azure MCP service capabilities and official Microsoft Learn service guidance

## Contact

For feedback, issues, or contributions, contact **Bulent Ozkir**:

- [bulento@microsoft.com](mailto:bulento@microsoft.com)
- [bulentozkir@hotmail.com](mailto:bulentozkir@hotmail.com)

## License

MIT License

Copyright (c) 2026 Bulent Ozkir

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
