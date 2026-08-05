---
name: azure-legacy-vm
description: >
  Assess previous-generation Azure virtual machines and VM scale sets using the
  vm-capacity-readiness-workbook. Use for July 2026 capacity restrictions,
  legacy VM inventory, VM series retirement, autoscale growth risk, quota and
  regional capacity readiness, replacement sizing, migration waves, availability
  set and zone compatibility, reservations, and post-migration verification.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Legacy VM

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Identify Azure VMs and VM scale sets that use previous-generation or retiring
sizes, quantify growth and continuity risk, and produce a validated migration
plan to current-generation VM families.

Use `vm-capacity-readiness-workbook.json` as the inventory and prioritization
model. In all findings, replace the informal label **legacy** with Microsoft's
precise lifecycle state:

- Previous-gen, next generation available
- Previous-gen, capacity limited
- Capacity restricted with retirement announced
- Retired

Capacity limitation isn't a shutdown notice. Retirement is a separate lifecycle
event with its own date and migration guidance.

## When to use this skill
- The user asks which VMs use old or legacy sizes
- July 2026 previous-generation capacity restrictions must be assessed
- VMSS autoscale might depend on constrained capacity
- A VM or VMSS size retirement notice is received
- The user needs replacement-family or migration-wave planning
- VM allocation, quota, resize, or zonal-capacity risk must be evaluated
- Reservations or on-demand capacity reservations affect a VM migration

## Workbook source and scope
The two discovered workbook copies are byte-identical. Use:

`vm-capacity-workbook/vm-capacity-readiness-workbook.json`

Record its SHA-256, assessment date, subscription, resource-group, and region
filters.

The workbook covers:

- `Microsoft.Compute/virtualMachines`
- `Microsoft.Compute/virtualMachineScaleSets`
- `Microsoft.Insights/autoscaleSettings`
- Advisor VM/VMSS Service Upgrade and Retirement metadata
- Advisor impacted-resource recommendations
- Service Health capacity-restriction advisories

It doesn't cover managed-service compute that doesn't expose VM or VMSS
resources in the selected subscription, such as some service pools. Assess Azure
Batch, AKS node pools, and other managed compute through their service APIs.

## Capacity-restriction baseline
Starting in July 2026, additional capacity is limited for these explicit series:

| Category | Affected series |
|----------|-----------------|
| Compute optimized | F, Fs, Fsv2 |
| General purpose | D, Ds, Dv2, Dsv2, Dv3, Dsv3, Dv4, Dsv4, Ddv4, Ddsv4, Dav4, Dasv4, B, Bs, Av2, Amv2 |
| Memory optimized | Ev3, Esv3, Ev4, Esv4, Edv4, Edsv4, Eav4, Easv4, G, Gs |
| Storage optimized | Ls, Lsv2 |

Do not infer impact from a generic `v1`-through-`v4` string match. Use the exact
series patterns and current Microsoft guidance.

Quota/capacity behavior:

| Scenario | Expected behavior |
|----------|-------------------|
| Existing running VM | Continues to operate |
| New subscription | Can't deploy affected series |
| Existing subscription with approved quota | Can deploy or redeploy, subject to actual capacity |
| Additional quota request | Not approved for affected series |
| Sufficient quota but no regional/zonal capacity | Allocation can still fail |
| Existing capacity reservation | Can continue within quota and reserved capacity |

Quota is permission, not a capacity guarantee.

## Guardrails
- Use read-only Azure CLI, Resource Graph, Advisor, Service Health, metrics, and
  quota queries.
- Do not resize, deallocate, restart, reimage, redeploy, update a VMSS model,
  change autoscale, exchange reservations, or create capacity reservations.
- Treat every resize as disruptive; running VMs restart and some changes require
  deallocation.
- Deallocation can release dynamic IP addresses and temporary/ephemeral data.
- Do not recommend a target SKU from family mapping alone.
- Do not assume a SKU listed for a region is currently allocatable.
- Never expose private IPs, application data, extensions, scripts, or credentials.
- Use UTC and distinguish inventory facts, lifecycle metadata, and live capacity.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Scope | Subscriptions, resource groups, regions, zones, and environments |
| Workload | Owner, application, criticality, SLO, RTO, and maintenance window |
| Compute | VM/VMSS size, instance count, orchestration, upgrade mode, autoscale |
| Platform | Availability set, zone, Spot, ephemeral OS, image generation |
| Performance | CPU, memory, disk IOPS/throughput/latency, network, and peaks |
| Storage | Premium support, controller, local/temp disk, Ultra Disk, encryption |
| Network | Accelerated networking, MANA support, IP behavior, load balancing |
| Capacity | Regional/family quota, SKU restrictions, zone support, ODCR |
| Commercial | RI, savings plan, licenses, and price-performance baseline |
| Lifecycle | Capacity restriction, retirement date, Advisor, Service Health |

If performance or owner evidence is unavailable, create a discovery task rather
than selecting an exact target size.

## Assessment procedure

### Step 1: Inventory VMs, VMSS, and autoscale
Inventory compute configuration:

```kusto
resources
| where type =~ "microsoft.compute/virtualmachines"
   or type =~ "microsoft.compute/virtualmachinescalesets"
| extend
    ResourceKind=iff(type =~ "microsoft.compute/virtualmachines", "VM", "VMSS"),
    TargetId=tolower(id),
    VmSize=iff(type =~ "microsoft.compute/virtualmachines",
      tostring(properties.hardwareProfile.vmSize), tostring(sku.name)),
    CurrentCapacity=iff(type =~ "microsoft.compute/virtualmachines",
      1, coalesce(toint(sku.capacity), 0)),
    OS=tostring(properties.storageProfile.osDisk.osType),
    Priority=tostring(properties.priority),
    AvailabilitySet=tostring(properties.availabilitySet.id),
    EphemeralOS=tostring(properties.storageProfile.osDisk.diffDiskSettings.option) =~ "Local",
    OrchestrationMode=tostring(properties.orchestrationMode),
    UpgradeMode=tostring(properties.upgradePolicy.mode),
    Zones=strcat_array(zones, ", ")
| project id, name, subscriptionId, resourceGroup, location, ResourceKind,
          VmSize, CurrentCapacity, OS, Priority, AvailabilitySet, EphemeralOS,
          OrchestrationMode, UpgradeMode, Zones, TargetId
```

Join autoscale settings:

```kusto
resources
| where type =~ "microsoft.insights/autoscalesettings"
| mv-expand Profile=properties.profiles
| extend
    TargetId=tolower(tostring(properties.targetResourceUri)),
    ProfileMin=toint(Profile.capacity.minimum),
    ProfileMax=toint(Profile.capacity.maximum)
| summarize AutoscaleMin=min(ProfileMin), AutoscaleMax=max(ProfileMax),
            AutoscaleProfiles=count() by TargetId
```

For each VMSS calculate:

`GrowthGap = max(AutoscaleMax - CurrentCapacity, 0)`

A positive growth gap on a capacity-limited series is Critical because expected
scale-out depends on constrained hardware.

### Step 2: Classify exact VM series
Normalize full SKU names into the workbook's series classes. Include size-name
variants such as:

- `Standard_D*`, `Standard_DS*`, `Standard_D*v2-v4`, and d/a/s variants
- `Standard_E*v3-v4` and d/a/s variants
- `Standard_F*`, `Standard_FS*`, `Standard_F*s_v2`
- `Standard_B*`, `Standard_A*_v2`, `Standard_A*m_v2`
- `Standard_G*`, `Standard_GS*`
- `Standard_L*s` and `Standard_L*s_v2`

Revalidate patterns when Azure introduces a new size naming variant. A blank
classification means the SKU isn't covered by this workbook, not that it is
current or healthy.

### Step 3: Distinguish capacity restriction from retirement
Use the workbook retirement dates only when they still match Microsoft guidance:

| Series | Published retirement |
|--------|----------------------|
| D, Ds, Dv2, Dsv2, Ls | 2028-05-01 |
| Av2, Amv2, B/Bs, F/Fs/Fsv2, G/Gs, Lsv2 | 2028-11-15 |
| Dv3/Dsv3, D/Ds v4 variants | Product active; capacity restricted |
| Ev3/Esv3 and E v4 variants | Product active; capacity restricted |

Also query all Advisor VM and VMSS retirement recommendations. These can cover
other SKUs, extensions, images, networking, or platform features.

```kusto
advisorresources
| where type =~ "microsoft.advisor/recommendations"
| extend Props=parse_json(properties)
| where tostring(Props.category) == "HighAvailability"
| where tostring(Props.extendedProperties.recommendationSubCategory)
    == "ServiceUpgradeAndRetirement"
| extend
    ResourceId=tolower(tostring(Props.resourceMetadata.resourceId)),
    Feature=tostring(Props.extendedProperties.retirementFeatureName),
    RetirementDate=todatetime(Props.extendedProperties.retirementDate),
    RecommendationTypeId=tostring(Props.recommendationTypeId)
| where isnotempty(ResourceId)
| project ResourceId, Feature, RetirementDate, RecommendationTypeId
```

Use `recommendationSubCategory`, not the legacy `recommendationControl` filter.

### Step 4: Review Service Health capacity advisories
Query customer-visible advisories:

```kusto
servicehealthresources
| where type =~ "microsoft.resourcehealth/events"
| extend
    EventType=tostring(properties.EventType),
    Status=tostring(properties.Status),
    Title=tostring(properties.Title),
    TrackingId=tostring(properties.TrackingId),
    Summary=tostring(properties.Summary),
    EventDate=todatetime(tolong(properties.ImpactMitigationTime))
| where EventType == "HealthAdvisory"
| where tolower(strcat(Title, " ", Summary)) has_any
    ("previous-generation", "previous generation",
     "capacity growth restriction", "v1-v4")
| project TrackingId, subscriptionId, Status, Title, EventDate
| order by EventDate desc
```

An empty result means no matching advisory is retained in Resource Graph. It
doesn't prove the subscription has no affected resources.

### Step 5: Quantify exposure and growth risk
Report:

- Affected VM instances
- Standalone VM count
- VMSS count and configured instances
- Autoscale growth at risk
- Instances with scheduled retirement
- Affected subscriptions, regions, zones, and series
- Risk concentration by workload and region

Workbook triage:

| Risk | Condition |
|------|-----------|
| Critical | VMSS `GrowthGap > 0` on capacity-limited series |
| High | Published retirement date exists |
| Medium | Product active but future capacity is restricted |

Adjust final priority for business criticality, restart behavior, Spot usage,
capacity reservation, zonal concentration, migration complexity, and deadline.

### Step 6: Build target-family candidates
Use directional family mappings:

| Source | Candidate families |
|--------|--------------------|
| D-series v2-v4 | Dv5/Dsv5, Dv6/Dsv6, or Dv7/Dsv7 |
| E-series v3-v4 | Ev5/Esv5, Esv6, or Esv7 |
| Av2/Amv2 | Bsv2/Basv2 or D/E v5-v6 |
| B/Bs | Bsv2/Basv2 or Dlsv5-v6 |
| F/Fs/Fsv2 | Dlsv5-v6, Dsv5, or Falsv6 |
| G/Gs | Lsv3/Lasv3 or Lsv4/Lasv4 |
| Ls/Lsv2 | Lsv3/Lasv3 or Lsv4/Lasv4 |

Select an exact size only after comparing vCPU, memory, architecture, sustained
performance, disk count, IOPS, throughput, cache, local disk, NIC bandwidth,
accelerated networking, price, and application benchmarks.

### Step 7: Validate target platform compatibility
For each candidate verify:

| Area | Validation |
|------|------------|
| Region/zone | SKU offered without blocking restrictions in every required zone |
| Quota | Total Regional vCPU and target-family vCPU quota |
| Capacity | Allocation confidence or approved ODCR where required |
| Boot/image | Generation 2, UEFI, Trusted Launch, current image |
| Storage | SCSI versus remote NVMe, OS support, stable mount identifiers |
| Network | MANA-compatible OS/driver and accelerated networking |
| Local disk | `d` suffix, temp NVMe, persistence assumptions |
| OS/app | Kernel, drivers, extensions, licenses, agents, and vendor support |

Discover target SKU restrictions:

```bash
az vm list-skus --location <region> --size <target-size> --all -o json
```

Check both quota tiers:

```bash
az vm list-usage --location <region> -o table
```

Quota includes allocated and deallocated VM cores. Sufficient quota doesn't
guarantee capacity.

### Step 8: Assess migration-specific constraints

**Standalone VM**
- Check `az vm list-vm-resize-options` for the current hardware cluster.
- A missing size can require deallocation or redeployment.
- A running resize causes restart.
- SCSI to remote NVMe isn't a direct resize path.
- Ephemeral OS disks and local/temp data require redeployment planning.
- Availability-set migrations can require coordinated deallocation of all VMs.
- Dynamic public/private IP behavior must be understood before deallocation.

**VM scale set**
- Confirm Uniform or Flexible orchestration and upgrade mode.
- Update the model and roll the target size to instances in controlled batches.
- Test autoscale minimum, maximum, and scale-out under the target quota/capacity.
- Validate zones independently.
- Preserve enough healthy instances during rolling migration.

**Spot workloads**
- Validate target SKU Spot availability, eviction tolerance, and fallback.

### Step 9: Assess reservation and capacity strategy
Keep commercial and capacity instruments distinct:

| Instrument | Purpose |
|------------|---------|
| Reserved VM Instance / savings plan | Discount |
| On-demand capacity reservation | Capacity assurance |
| vCPU quota | Subscription permission |

Review current RI term and size flexibility before migration. Some previous-gen
families no longer support new or renewed reservations even while product-active.

Existing ODCRs for affected series continue within quota and reserved capacity.
Shared reservations can fail when a consuming subscription needs quota that can
no longer be increased.

Do not buy a target-family RI or ODCR until sizing, region, zone, migration
schedule, and workload demand are validated.

### Step 10: Plan migration waves and verification
Use controlled waves:

1. Inventory and owner confirmation
2. Performance baseline and target selection
3. Image, driver, storage, network, quota, and capacity readiness
4. Non-production pilot
5. Representative production canary
6. Availability-set or VMSS rolling waves
7. Full migration
8. Legacy-size and commitment cleanup

Validate:
- Boot, disks, mounts, drivers, network, extensions, identity, and monitoring
- Functional, load, latency, IOPS, throughput, and failover behavior
- Autoscale and one-zone-loss capacity
- Backup, restore, DR, rollback, and operational runbooks
- Cost and performance against baseline
- No old-size instances remain in VMSS or IaC
- Advisor and internal retirement register are cleared

## Scoring
Calculate a Legacy VM Migration Readiness score:

| Domain | Points |
|--------|--------|
| Complete VM/VMSS/autoscale inventory | 0-15 |
| Correct lifecycle and retirement classification | 0-15 |
| Workload sizing and target compatibility | 0-20 |
| Regional, zonal, quota, and capacity readiness | 0-20 |
| Migration, rollback, and test readiness | 0-20 |
| Owner, schedule, commercial plan, and verification | 0-10 |
| **Total** | **0-100** |

| Score | Readiness |
|-------|-----------|
| 90-100 | Ready |
| 70-89 | On track |
| 40-69 | At risk |
| 0-39 | Critical |

Missing evidence earns zero points. Existing operation isn't evidence that future
scale-out or redeployment will succeed.

## Accepted exceptions
Each exception must include:

| Field | Requirement |
|-------|-------------|
| Resource/series | Exact VM or VMSS and size |
| Lifecycle | Capacity limited, retirement announced, or retired |
| Reason | Business and technical rationale |
| Continuity impact | Scale, restart, redeploy, SLA, and deadline risk |
| Compensating control | ODCR, spare capacity, alternate zone/region, or continuity plan |
| Owner | Accountable approver |
| Review/expiry | Before retirement or next growth event |

Exceptions don't guarantee allocation or extend a retirement date.

## Expected output

## Azure Legacy VM Readiness Report

| Field | Value |
|-------|-------|
| Scope | Subscriptions, resource groups, and regions |
| Assessment date | YYYY-MM-DD UTC |
| Affected instances | Count |
| VMSS growth at risk | Count |
| Retirement-scheduled instances | Count |
| Product-active constrained instances | Count |
| Critical/high/medium findings | Counts |
| Readiness score | XX/100 and status |

Required sections:
1. **Executive summary**
2. **Scope, workbook hash, sources, and limitations**
3. **Affected series and lifecycle classification**
4. **Standalone VM inventory**
5. **VMSS and autoscale growth risk**
6. **Target-family and compatibility matrix**
7. **Quota, capacity, zone, and ODCR readiness**
8. **Migration waves, blockers, and deadlines**
9. **Reservations and cost implications**
10. **Accepted exceptions**
11. **Commands, queries, and references**

Every finding must include resource, size/series, lifecycle, region/zone,
instances, growth gap, target candidates, blockers, owner, priority, deadline,
next action, and verification.

## Remediation guidance
- Suggest only; never resize or deallocate from this skill.
- Validate write syntax with `GetAzCliHelp` when available.
- Use IaC preview/plan before model changes.
- Pilot target images and hardware before production.
- Preserve rollback and redundancy throughout migration.
- Open quota and capacity work early; neither is guaranteed.
- Use official retirement and migration guidance for exact deadlines.

## References
- Workbook: `vm-capacity-workbook/vm-capacity-readiness-workbook.json`
- Capacity restrictions: https://learn.microsoft.com/azure/virtual-machines/migration/sizes/previous-gen-series-capacity-limitations
- Previous-gen lifecycle: https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirement/retirement-overview
- Retired-size migration: https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirement/d-ds-dv2-dsv2-ls-series-migration-guide
- v6/v7 migration: https://learn.microsoft.com/azure/virtual-machines/migration/sizes/sizes-v6-v7-migration-overview
- VM resize: https://learn.microsoft.com/azure/virtual-machines/sizes/resize-vm
- vCPU quotas: https://learn.microsoft.com/azure/virtual-machines/quotas
- Capacity reservation: https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-overview
- Advisor retirements: https://learn.microsoft.com/azure/advisor/advisor-how-to-use-service-upgrade-retirement-recommendations

## Sample output

> Redacted example with illustrative values.

## Azure Legacy VM Readiness Report

| Field | Value |
|-------|-------|
| Scope | 8 subscriptions, 5 regions |
| Assessment date | 2026-08-04 UTC |
| Affected instances | 186 |
| VMSS growth at risk | 42 instances |
| Retirement-scheduled instances | 73 |
| Product-active constrained instances | 113 |
| Critical/high/medium findings | 4 / 18 / 27 |
| Readiness score | 58/100 - At risk |

### Top findings

| Priority | Resource | Current state | Risk | Next action |
|----------|----------|---------------|------|-------------|
| Critical | checkout-vmss | Dsv3, 12 current, autoscale max 30 | 18-instance growth depends on restricted capacity | Validate Dsv6 in all zones and quota |
| High | finance-db-01 | Dsv2, retirement 2028-05-01 | Stateful VM; target requires storage validation | Benchmark Dsv5 and Dsv6 paths |
| High | batch-legacy-as | Fsv2 availability set | Coordinated deallocation and restart required | Build canary and migration window |
| Medium | api-vm-03 | Dsv4, product active | Capacity growth restricted, no retirement announced | Move next refresh to current generation |

Capacity restriction and retirement findings are reported separately. No resize,
deallocation, quota request, or reservation change was executed.
