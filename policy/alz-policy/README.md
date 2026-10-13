# Azure Landing Zones (ALZ) custom policies, audit first

Every custom policy of the [Azure landing zones](https://azure.github.io/Azure-Landing-Zones/policy/) reference implementation, **converted to audit by default**, plus the policies that are authored in this repository, published as **one initiative** by one PowerShell script. Nothing blocks or changes a resource until you say so: the policy definitions and the initiative both default to an audit-mode effect, and each policy has its own effect parameter, so you can switch individual policies to `Deny`, `DeployIfNotExists`, `Modify`, `Append` or `DenyAction` later, in the assignment, without touching the definitions.

ALZ defines most of these policies with enforcing defaults: 137 of the 149 custom definitions (81 of the 93 active ones) default to Deny, DeployIfNotExists, Modify, Append or DenyAction upstream. In [definitions/](definitions) every one of them now defaults to `Audit` or `AuditIfNotExists`, so you can measure your estate against the ALZ guardrails before enforcing anything. The effect that upstream applies stays selectable and is recorded in each definition's `metadata.alzUpstreamEffect`; the [catalog](policy-catalog.md) lists it for every policy.

## What is in this folder

| Path | Purpose |
| --- | --- |
| [Deploy-AlzPolicy.ps1](Deploy-AlzPolicy.ps1) | Publishes the definitions and the initiative at a management group or subscription. |
| [definitions/](definitions) | The 93 active ALZ custom policy definitions, converted to audit by default. Only their effect handling (and one documented policy rule adjustment) differs from the upstream files. |
| [definitions/deprecated/](definitions/deprecated) | The 56 definitions that upstream flags as deprecated, converted the same way. Published only with `-IncludeDeprecated`. |
| [local-definitions/](local-definitions) | Policies authored in this repository, not imported from ALZ (today `Audit-RHEL-Hybrid-Benefit`). The import never touches this folder. See [Local definitions](#local-definitions). |
| [policy-catalog.md](policy-catalog.md) | Every policy with its default, upstream default and selectable effects, effect parameter name and the roles it needs, plus every other initiative parameter. |
| [Import-AlzPolicy.ps1](Import-AlzPolicy.ps1) | Imports the definitions from the upstream library (pinned to a release tag) and converts them to audit by default. `-CatalogOnly` only regenerates the catalog from the files on disk. |
| [Test-AlzPolicy.ps1](Test-AlzPolicy.ps1) | Offline checks of the imported and the local definitions, the initiative and the catalog, including a run of the deploy script against a simulated Azure Resource Manager. |
| [AlzPolicy.Common.ps1](AlzPolicy.Common.ps1) | Shared logic: converts definitions, builds and validates the initiative, renders the catalog. |
| [alz-library-source.json](alz-library-source.json) | Provenance and conversion record: upstream repository, release tag, commit, counts, one fingerprint per upstream definition and the documented policy rule adjustments. |

Imported from [Azure/Azure-Landing-Zones-Library](https://github.com/Azure/Azure-Landing-Zones-Library) `platform/alz` at tag `platform/alz/2026.10.0`. That library is the reference set of ALZ policies, archetypes and management group architecture.

## How the conversion works

`Import-AlzPolicy.ps1` converts every upstream definition once and stores the result in `definitions/`. The conversion changes only how the effect is handled:

- **Audit by default.** The default of the `effect` parameter becomes `Audit` (for Deny, Modify, Append and DenyAction) or `AuditIfNotExists` (for DeployIfNotExists). Definitions that already audited upstream (12) are left as they are.
- **The upstream effect stays selectable.** If a definition did not offer the audit-mode effect, it is added to its allowed values (77 of the 149 definitions, 22 of the 93 active ones). A hard-coded effect (5 definitions) becomes an `effect` parameter. The effect that upstream applies by default is recorded in `metadata.alzUpstreamEffect`. Every policy also accepts `Disabled`.
- **Nothing else changes, except the [adjusted policy rules](#adjusted-policy-rules) below.** The policy condition, `details`, the other parameters and all other metadata are upstream's. The import stores a SHA-256 fingerprint of every upstream definition (without its effect handling) in [alz-library-source.json](alz-library-source.json), refuses to write a definition whose fingerprint changed, and `Test-AlzPolicy.ps1` checks it again. After an import, `git diff` shows exactly which lines the conversion touched.

| Enforcing effect upstream | Audit-mode default | Active policies |
| --- | --- | --- |
| `Deny` | `Audit` | 61 |
| `DeployIfNotExists` | `AuditIfNotExists` | 18 |
| `Append` | `Audit` | 5 |
| `DenyAction` | `Audit` | 3 |
| `Modify` | `Audit` | 2 |
| none (audit-only policies) | `Audit` | 4 |

`AuditIfNotExists` is used for the DeployIfNotExists policies because plain `Audit` would flag every resource that matches the condition, not only those that lack the deployment. The three DenyAction policies use plain `Audit`: `AuditIfNotExists` needs a related resource type that they do not have, and `AuditAction` is not in the list of Azure Policy effects, so it is not used. There is no real audit counterpart to blocking a delete: for these policies `Audit` only reports matching resources, if Azure Policy evaluates their type at all, and never blocks anything. Switch them to `DenyAction` to protect against deletion.

### Adjusted policy rules

One imported policy rule is deliberately different from upstream. Each adjustment is defined in `$script:AlzPolicyRuleAdjustments` in [AlzPolicy.Common.ps1](AlzPolicy.Common.ps1), applied by the import after the conversion, recorded in `metadata.alzAdjustment` of the definition and, with the fingerprint of the result, in [alz-library-source.json](alz-library-source.json), and listed in the [catalog](policy-catalog.md#adjusted-policy-rules). The import stops when an adjustment no longer finds anything to change in upstream's rule, so each one is reviewed against every new release.

| Policy | Adjustment |
| --- | --- |
| `Audit-AzureHybridBenefit` | The Windows Server version list is removed from the rule. Upstream reports only images whose `Microsoft.Compute/imageSKU` matches `2008-R2-SP1*`, `2012-*`, `2016-*`, `2019-*` or `2022-*`. Now every `MicrosoftWindowsServer` / `WindowsServer` image that does not use Azure Hybrid Benefit (`licenseType` other than `Windows_Server`) is reported, whatever its version. |

## Local definitions

Policies that are authored in this repository, not imported from ALZ, live in [local-definitions/](local-definitions). The import never touches that folder, and it refuses to run when `definitions/` holds a file that it did not create, because it replaces that folder completely. A local definition uses the same file layout as the others (`{ "name", "type", "properties" }`, `policyType` `Custom`, file name = policy name) and goes into the initiative like the imported ones. It is never converted, so it has to audit by default already: an `effect` parameter that defaults to `Audit` or `AuditIfNotExists` and offers that default and `Disabled`. `Test-AlzPolicy.ps1` checks this, and the published copy is marked `metadata.alzOrigin = local`. After adding or editing one, regenerate the catalog without any download and run the tests:

```powershell
./Import-AlzPolicy.ps1 -CatalogOnly
./Test-AlzPolicy.ps1
```

| Policy | Purpose |
| --- | --- |
| `Audit-RHEL-Hybrid-Benefit` | Reports Red Hat BYOS images (`redhat` / `rhel-byos`) of virtual machines and scale sets whose `licenseType` is not `RHEL_BYOS`. Defaults to `Audit`; `Deny` and `Disabled` are selectable. |

The image SKU of that policy is matched with the parameter `imageSkuPattern` (initiative parameter `Audit_RHEL_Hybrid_Benefit_imageSkuPattern`), which defaults to `rhel-*`. It replaces a hard-coded list of 27 SKUs (`rhel-lvm74` to `rhel-lvm85` and some `rhel-raw` images). That list missed 28 of the 50 SKUs that Azure published under `redhat:rhel-byos` when this was written: every RHEL 8.6 to 8.10 and 9.x image, so VMs created from them were never reported. `rhel-*` matches every current SKU and every future one. Narrow it, for example to `rhel-lvm9*`, to limit the policy to some versions; the pattern can contain one `*` wildcard and is not case sensitive.

## How the initiative works

The script generates the initiative around the converted and the local definitions. Every policy gets its own effect parameter, named after the policy with every non-alphanumeric character replaced by `_`, plus `_effect`: `Deny-Storage-CopyScope` becomes `Deny_Storage_CopyScope_effect`. Its default is the definition's audit-mode effect, so the initiative and the definition always agree, and its allowed values are the ones the policy supports, plus `Disabled`.

- **Other inputs** (for example `Deny_Subnet_Without_Nsg_excludedSubnets`) are namespaced per policy with the default of their definition. Only `mandatoryTags`, `allowedVnets` and the deprecated diagnostics inputs are shared, because they are the same knob for several policies. All 97 are listed in the [catalog](policy-catalog.md).
- **Nothing is required at assignment.** 29 inputs have no upstream default (names, regions, resource IDs for policies that deploy things). They get a flagged placeholder (`""`, `[]` or the first allowed value) that only matters once you switch that policy to a deploying effect; set a real value then. Until it is set, the audit result of such a policy (for example `Deploy-DDoSProtection` or `Deploy-Private-DNS-Generic`) is not meaningful; set that policy to `Disabled` if you do not plan to use it.
- Parameter names do not change between runs or when `-IncludeDeprecated` is used, so existing assignments keep working.

## Deploy

Needs PowerShell 7.2 or later and the `Az.Accounts` module, and permission to write policy definitions and initiatives at the target (for example *Resource Policy Contributor*). Preview with `-WhatIf` first; it signs in and reads, but writes nothing.

```powershell
# Management group (the usual ALZ choice; assignable there and below)
./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -TenantId <tenant-id> -WhatIf
./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -TenantId <tenant-id>

# Or a subscription
./Deploy-AlzPolicy.ps1 -SubscriptionId <subscription-id> -TenantId <tenant-id>
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ManagementGroupId` / `-SubscriptionId` | required, one of them | Where the definitions and the initiative are published. |
| `-TenantId` | current Az context | Tenant to sign in to. |
| `-DefinitionPrefix` | `alz-` | Prefix of the published definition names (`alz-Deny-Storage-CopyScope`). It keeps them apart from definitions that an ALZ accelerator deploys with the upstream names; use `''` to keep the upstream names. A definition name is limited to 64 characters, so a prefix plus policy name that is longer is cut short and gets a hash suffix (one policy with the default prefix); `metadata.alzName` always holds the upstream name. |
| `-InitiativeName`, `-DisplayName` | `alz-custom-policies` | Name and display name of the initiative. |
| `-IncludeDeprecated` | off | Also publish the 56 deprecated policies (258 initiative parameters instead of 191). |
| `-ExcludePolicy` | none | Policy names to leave out, for example `Deny-Storage-SFTP`. |
| `-Environment` | `AzureCloud` | `AzureUSGovernment` and `AzureChinaCloud` skip the policies that upstream does not support there. |
| `-Remove` | | Remove what this package published (see [Remove](#remove)). |
| `-ExportOnly -OutputPath <dir>` | | Write the generated JSON without signing in or calling Azure. `-OutputPath` alone also writes it before deploying. |
| `-UseDeviceAuthentication`, `-SkipLogin` | | Sign-in behaviour. |

What the script guarantees:

- It creates **no assignment**.
- It publishes the definitions first, then the initiative, and stops before the initiative if any definition fails. Publishing is idempotent, so you can fix the cause (or use `-ExcludePolicy`) and run again.
- It never overwrites a definition or initiative it did not publish: everything it publishes carries `metadata.managedBy = azurethings-alz-policy`, and a name clash with anything else stops the run before any write.
- It retries throttling (HTTP 429/5xx) and checks what Azure stored.

Azure allows 500 policy definitions and 200 initiatives per scope, 400 parameters per initiative, and 64 characters in a definition name. This package uses 94 (or 150) definitions, 1 initiative and 191 (or 258) parameters.

## Assign

Audit everything. No parameters, no managed identity:

```powershell
$scope = '/providers/Microsoft.Management/managementGroups/contoso'
$set = Get-AzPolicySetDefinition -Name alz-custom-policies -ManagementGroupName contoso
New-AzPolicyAssignment -Name alz-audit -DisplayName 'ALZ custom policies (audit)' -Scope $scope -PolicySetDefinition $set
```

Names of assignments at a management group are limited to 24 characters. A definition that you assign on its own audits as well (for example `alz-Deny-Storage-CopyScope`); to enforce it, set its `effect` parameter.

Switch some policies to enforce. Use the parameter names from the [catalog](policy-catalog.md); anything you do not set keeps auditing:

```powershell
New-AzPolicyAssignment -Name alz-enforce -Scope $scope -PolicySetDefinition $set -PolicyParameterObject @{
    Deny_Storage_CopyScope_effect  = 'Deny'
    Deny_Subnet_Without_Nsg_effect = 'Deny'
    Append_KV_SoftDelete_effect    = 'Append'
}
```

```bash
az policy assignment create --name alz-enforce --scope /providers/Microsoft.Management/managementGroups/contoso \
  --policy-set-definition /providers/Microsoft.Management/managementGroups/contoso/providers/Microsoft.Authorization/policySetDefinitions/alz-custom-policies \
  --params '{ "Deny_Storage_CopyScope_effect": { "value": "Deny" } }'
```

In the portal: **Policy > Definitions**, open the initiative, **Assign**, and on **Parameters** clear *Only show parameters that need input or review* to see the effect of every policy.

### Deploy and Modify effects need an identity

`DeployIfNotExists` and `Modify` act through a managed identity. Create the assignment with an identity and a location, set any inputs the policy needs (the parameters marked `placeholder` in the catalog), then give the identity the roles listed for that policy in the catalog:

```powershell
$assignment = New-AzPolicyAssignment -Name alz-deploy -Scope $scope -PolicySetDefinition $set `
    -PolicyParameterObject @{ Deploy_Storage_sslEnforcement_effect = 'DeployIfNotExists' } `
    -IdentityType SystemAssigned -Location westeurope
New-AzRoleAssignment -ObjectId ($assignment.IdentityPrincipalId ?? $assignment.Identity.PrincipalId) `
    -RoleDefinitionName 'Storage Account Contributor' -Scope $scope
```

Existing non-compliant resources are fixed by a remediation task, not by the assignment itself. The portal grants the roles for you when you tick **Create a Managed Identity** on the **Remediation** tab.

## Remove

Delete the assignments of the initiative first, then run the script with the same scope, `-DefinitionPrefix` and `-InitiativeName` that you deployed with:

```powershell
./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -Remove -WhatIf
./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -Remove
```

It deletes the initiative first and then the definitions, and only resources at that exact scope that carry this package's `metadata.managedBy` marker; anything else with a similar name is left alone and reported. Azure refuses to delete an initiative that is still assigned, and the script stops there without touching the definitions. `-IncludeDeprecated` and `-ExcludePolicy` do not matter: it removes everything the package may have published with that prefix.

## Update from upstream

```powershell
./Import-AlzPolicy.ps1 -Ref <release-tag>   # for example platform/alz/2026.10.0; tags are listed at github.com/Azure/Azure-Landing-Zones-Library/tags
./Test-AlzPolicy.ps1
```

The import converts the release the same way, replaces `definitions/` (edits made there are overwritten: change an effect per assignment instead; `local-definitions/` stays as it is), rewrites [alz-library-source.json](alz-library-source.json) and regenerates [policy-catalog.md](policy-catalog.md). Run `./Deploy-AlzPolicy.ps1` again to publish the update; parameter names of unchanged policies stay the same.

## Validate

`./Test-AlzPolicy.ps1` needs no Azure access. It checks that every definition file defaults to an audit-mode effect, records and still offers its upstream effect, and equals its upstream original in everything but the effect handling and the documented adjustments (fingerprints); that every local definition audits by default; that the initiative defaults to the same effects and needs no input; that parameter names are stable; that the catalog is current; and that the deploy script behaves (fresh deployment, re-run, `-WhatIf`, throttling, name clashes, rejected definitions, subscription scope, cloud filtering, removal) against a simulated Azure Resource Manager.

## Source and licence

The definitions derive from [Azure/Azure-Landing-Zones-Library](https://github.com/Azure/Azure-Landing-Zones-Library) (MIT, © Microsoft Corporation) and are converted to audit by default as described above; the licence is in [LICENSE-Azure-Landing-Zones-Library.txt](LICENSE-Azure-Landing-Zones-Library.txt). Each imported definition keeps its upstream `metadata.source` and `version` and records `alzUpstreamEffect`; the published copy adds `managedBy`, `alzName` and `alzLibraryVersion`. The local definitions are this repository's own; their published copies add `managedBy`, `alzName` and `alzOrigin`.
