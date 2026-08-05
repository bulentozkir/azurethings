---
name: well-architected-operational-excellence
description: >
  Run an Azure Well-Architected Operational Excellence review covering DevOps
  culture, operational standards, software development lifecycle, tooling,
  source control, infrastructure as code, workload supply chain, observability,
  incident management, testing, automation, and safe deployments. Use for
  production-readiness, DevOps maturity, and operational improvement assessments.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Well-Architected Operational Excellence

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Assess whether an Azure workload is developed, deployed, observed, operated, and
improved through repeatable, secure, automated, and learning-focused practices.
Evaluate all Microsoft Well-Architected `OE:01` through `OE:11` controls and
produce a prioritized operating-model and DevOps action plan.

## Guardrails
- Use read-only Azure, repository, pipeline, monitoring, and incident evidence.
- Do not deploy, approve, merge, rerun, cancel, roll back, or alter pipelines.
- Do not expose source, secrets, incident/private data, identities, or webhook URLs.
- Don't infer maturity from the presence of a tool. Require operating evidence.
- Use UTC and record assessment period, scope, repositories, and evidence freshness.

## Pre-check

| Field | Required value |
|-------|----------------|
| Workload | Purpose, owner, critical flows, SLOs, environments |
| Teams | Product, engineering, platform, security, SRE, support responsibilities |
| Repositories | Code, IaC, config, policy, runbooks, and documentation |
| Delivery | Pipelines, environments, approvals, artifacts, deployment strategy |
| Operations | On-call, alerts, dashboards, runbooks, incidents, changes |
| Quality | Test strategy, quality gates, security and reliability validation |
| Automation | Routine, emergency, remediation, and lifecycle automation |
| Evidence period | Default: last 90 days plus latest major incident/release |

If evidence is unavailable, score `Not assessed` as zero rather than assuming a
practice exists.

## Assessment procedure

### Step 1: Define workload and operating boundaries
Map critical flows, Azure resources, dependencies, environments, repositories,
pipelines, owners, support hours, escalation, and shared platform responsibilities.
Clarify which team owns each control and decision.

### Step 2: OE:01 - DevOps culture and accountability
Review:

- Shared product/operations goals and SLO ownership
- Clear roles, decision rights, service ownership, and escalation
- Blameless incident learning and psychological safety
- Backlog ownership for reliability, security, performance, and technical debt
- Feedback loops between users, support, engineering, and operations
- Measurable improvement objectives and review cadence

Interview evidence must be corroborated with retrospectives, action items, and
completed improvements.

### Step 3: OE:02 - Standardize operations
Inventory routine, ad-hoc, and emergency tasks:

| Task type | Required evidence |
|-----------|-------------------|
| Routine | Versioned runbook, owner, prerequisites, safe automation |
| Ad-hoc | Decision log, approval, validation, lessons captured |
| Emergency | Break-glass path, incident command, rollback, audit |
| Maintenance | Schedule, notification, suppression, success criteria |

Check runbook accuracy, last test, dependencies, permissions, error handling,
idempotency, and rollback. Remove tribal-knowledge dependencies.

### Step 4: OE:03 - Formalize development practices
Review ideation-to-production flow:

- Requirements and acceptance criteria
- Architecture/security/reliability review
- Branching, pull requests, review, and traceability
- Environment promotion and configuration management
- Definition of done, release notes, and documentation
- Deprecation, feature flags, data/schema compatibility, and rollback

Production hotfixes require the same traceability and retrospective controls.

### Step 5: OE:04 - Standardize tools and quality
Assess:

- Approved toolchain and supported versions
- Source control for code, IaC, config, policy, dashboards, and runbooks
- Reusable templates, style guides, linters, scanners, and dependency management
- Artifact repositories, immutability, signing, provenance, and SBOM
- Developer environments and reproducible builds
- Tool ownership, lifecycle, support, and retirement

Count exceptions and manual divergence, not only tool adoption.

### Step 6: OE:05 - Infrastructure as code
Require:

- Declarative, modular, versioned IaC for repeatable environments
- Review, lint, validation, security/policy, and what-if/plan gates
- Parameter/secrets separation and managed identity
- State and drift management
- Resource locks and deletion safeguards
- Environment parity with intentional differences documented
- Tested rollback/redeployment and disaster recovery for platform configuration

Compare deployed Azure inventory and configuration with IaC ownership. Manual
resources and unmanaged drift are findings.

### Step 7: OE:06 - Workload supply chain
Trace change from commit to production:

1. Authenticated source and review
2. Reproducible build and immutable artifact
3. Unit/integration/security/IaC tests
4. Environment promotion without rebuild
5. Approval and quality gates
6. Progressive exposure and health validation
7. Automated rollback or safe halt
8. Release evidence and audit trail

Check least privilege, isolated runners, protected environments, dependency
pinning, secret handling, concurrency, retention, and supply-chain compromise.

### Step 8: OE:07 - Observability
Use Azure Monitor MCP capabilities for workspace/table discovery, KQL, resource
logs, metrics, activity, alerts, and instrumentation.

Review:
- Critical-flow SLIs, SLOs, health model, and error budgets
- Correlated metrics, logs, traces, events, changes, and dependencies
- Consistent resource/app identity and deployment version
- Actionable alerts, owned dashboards, and diagnostic runbooks
- Data quality, sampling, retention, access, cost, and sensitive-data controls
- Observability-as-code and test coverage

Telemetry volume isn't observability. Demonstrate diagnosis and decision use.

### Step 9: OE:08 - Incident management
Review last major incidents and exercises:

- Detection, severity, commander, communications, and escalation
- Triage access, dashboards, runbooks, and decision log
- Containment, mitigation, recovery, and validation
- Customer/regulatory communication
- Blameless postmortem, contributing factors, and action owners
- Time to detect, acknowledge, mitigate, and resolve
- Recurrence and completion of preventive actions

Architecture should support isolation, rollback, degraded modes, and evidence
collection under pressure.

### Step 10: OE:09 - Testing
Map tests to business risks:

- Unit, contract, integration, end-to-end, and acceptance
- Performance, scale, soak, and capacity
- Failure injection, resilience, backup restore, and DR
- Security, privacy, accessibility, and compliance
- Infrastructure, policy, deployment, rollback, and migration
- Production validation and synthetic monitoring

Require production-like environments, test data controls, pass/fail thresholds,
flaky-test ownership, and evidence that failures block promotion.

### Step 11: OE:10 - Automation
Score automation by reliability, not count. Validate:

- Clear return on investment and owner
- Idempotency, retries, timeouts, concurrency, and partial-failure behavior
- Least privilege, managed identity, secretless operation, and audit
- Dry run/preview, approval boundaries, rollback, and kill switch
- Monitoring, alerting, tests, versioning, and maintenance
- Human-in-the-loop for ambiguous/high-impact decisions

Avoid automating an unstable or undocumented process.

### Step 12: OE:11 - Safe deployments
Review:

- Small changes and independent deployability
- Rings/canaries/blue-green/slots and progressive traffic
- Predeployment checks, schema compatibility, and feature flags
- Health gates based on SLOs and business signals
- Automatic halt/rollback with bounded decision time
- Roll-forward and emergency deployment procedures
- Capacity buffer, dependency readiness, and in-flight work
- Postdeployment observation and release verification

Correlate recent incidents to deployment controls and improve the pipeline.

### Step 13: Measure outcomes
Use deployment frequency, change lead time, change failure rate, recovery time,
rework, manual intervention, alert quality, action-item completion, toil, and
SLO/error-budget results. Avoid comparing teams without context.

## Scoring
Score each `OE:01`-`OE:11` from 0 to 5:

| Score | Meaning |
|-------|---------|
| 5 | Standardized, automated, measured, tested, continuously improved |
| 3 | Implemented with material inconsistency or evidence gaps |
| 1 | Ad hoc, manual, or person-dependent |
| 0 | Absent or not assessed |
| N/A | Demonstrably not applicable; excluded |

Overall score is earned/applicable points * 100. Maturity: 90+ Optimized,
70-89 Managed, 40-69 Developing, below 40 Initial.

## Accepted exceptions
Require exact control/scope, reason, operational risk, compensating control,
owner, approval, and expiry/review date.

## Expected output

## Azure Operational Excellence Review Report

Include scope, score, OE:01-OE:11 scorecard, delivery flow, IaC/drift,
observability, incidents, testing, automation, deployment safety, outcome
metrics, prioritized roadmap, exceptions, evidence, and references.

Every finding includes control, evidence, risk, owner, recommendation, effort,
target date, and verification.

## Remediation guidance
- Suggest only; don't change repositories, pipelines, or Azure resources.
- Prefer standardized reusable improvements over one-off fixes.
- Introduce automation after stabilizing the process.
- Pilot pipeline and governance changes with rollback and success metrics.

## References
- Checklist: https://learn.microsoft.com/azure/well-architected/operational-excellence/checklist
- Principles: https://learn.microsoft.com/azure/well-architected/operational-excellence/principles
- Observability: https://learn.microsoft.com/azure/well-architected/operational-excellence/observability
- Safe deployments: https://learn.microsoft.com/azure/well-architected/operational-excellence/safe-deployments
- IaC: https://learn.microsoft.com/azure/well-architected/operational-excellence/infrastructure-as-code-design

## Sample output

| Field | Value |
|-------|-------|
| Score | 64/100 - Developing |
| Strongest | OE:05 IaC |
| Highest risk | OE:11 Safe deployments |

Top finding: production deployments have no progressive exposure or automatic
health gate; three recent incidents required manual rollback.
