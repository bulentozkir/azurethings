# Azure Landing Zones (ALZ) custom policies, audit first

Every custom policy of the [Azure landing zones](https://azure.github.io/Azure-Landing-Zones/policy/) reference implementation, published as **one initiative** by one PowerShell script. Assigning the initiative only **audits**. Each policy has its own effect parameter, so you can switch individual policies to `Deny`, `DeployIfNotExists`, `Modify`, `Append` or `DenyAction` later, in the assignment, without touching the definitions.

ALZ defines these policies with enforcing defaults: 81 of the 93 active definitions default to Deny, DeployIfNotExists, Modify, Append or DenyAction upstream. This package flips every one of them to audit at the initiative level, so you can measure your estate against the ALZ guardrails before enforcing anything.

## What is in this folder

| Path | Purpose |
| --- | --- |
| [Deploy-AlzPolicy.ps1](Deploy-AlzPolicy.ps1) | Publishes the definitions and the initiative at a management group or subscription. |
| [definitions/](definitions) | The 93 active ALZ custom policy definitions, unchanged copies of the upstream files. |
| [definitions/deprecated/](definitions/deprecated) | The 56 definitions that upstream flags as deprecated. Published only with `-IncludeDeprecated`. |
| [policy-catalog.md](policy-catalog.md) | Every policy with its default and selectable effects, effect parameter name and the roles it needs, plus every other initiative parameter. |
| [Import-AlzPolicy.ps1](Import-AlzPolicy.ps1) | Re-imports the definitions from the upstream library (pinned to a release tag). |
| [Test-AlzPolicy.ps1](Test-AlzPolicy.ps1) | Offline checks, including a run of the deploy script against a simulated Azure Resource Manager. |
| [AlzPolicy.Common.ps1](AlzPolicy.Common.ps1) | Shared logic: adapts definitions, builds and validates the initiative, renders the catalog. |
| [alz-library-source.json](alz-library-source.json) | Provenance: upstream repository, release tag, commit and counts. |

Imported from [Azure/Azure-Landing-Zones-Library](https://github.com/Azure/Azure-Landing-Zones-Library) `platform/alz` at tag `platform/alz/2026.10.0`. That library is the reference set of ALZ policies, archetypes and management group architecture.

## How the initiative works

Almost every definition has an `effect` parameter. The script publishes the definitions with one systematic change and generates the initiative around them:

- **Audit-mode effect.** If a definition does not already allow an audit effect, it is added to the allowed values (22 definitions). A definition with a hard-coded effect (5 of them) gets an `effect` parameter whose default stays the upstream effect. Nothing else changes: the policy condition, `details` and every other parameter stay as upstream, and `Test-AlzPolicy.ps1` proves it.
- **One effect parameter per policy**, named after the policy with every non-alphanumeric character replaced by `_`, plus `_effect`: `Deny-Storage-CopyScope` becomes `Deny_Storage_CopyScope_effect`. Its default is the audit-mode effect and its allowed values are the ones the policy supports, plus `Disabled`.

| Enforcing effect of the policy | Audit-mode default | Policies |
| --- | --- | --- |
| `Deny` | `Audit` | 61 |
| `DeployIfNotExists` | `AuditIfNotExists` | 18 |
| `Append` | `Audit` | 5 |
| `DenyAction` | `AuditAction` | 3 |
| `Modify` | `Audit` | 2 |
| none (audit-only policies) | `Audit` | 4 |

`AuditAction` is the audit mode of `DenyAction`: attempted deletes are logged instead of blocked. It is the value that Microsoft itself preselects for its built-in `DenyAction` policy *Users must authenticate with multi-factor authentication to delete resources* (see [Tutorial: Self-enforce MFA through Azure Policy](https://learn.microsoft.com/azure/governance/policy/tutorials/mfa-enforcement)), although the general effects reference does not list it.

- **Other inputs** (for example `Deny_Subnet_Without_Nsg_excludedSubnets`) are namespaced per policy with the upstream default. Only `mandatoryTags`, `allowedVnets` and the deprecated diagnostics inputs are shared, because they are the same knob for several policies. All 96 are listed in the [catalog](policy-catalog.md).
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
| `-IncludeDeprecated` | off | Also publish the 56 deprecated policies (256 initiative parameters instead of 189). |
| `-ExcludePolicy` | none | Upstream policy names to leave out, for example `Deny-Storage-SFTP`. |
| `-Environment` | `AzureCloud` | `AzureUSGovernment` and `AzureChinaCloud` skip the policies that upstream does not support there. |
| `-Remove` | | Remove what this package published (see [Remove](#remove)). |
| `-ExportOnly -OutputPath <dir>` | | Write the generated JSON without signing in or calling Azure. `-OutputPath` alone also writes it before deploying. |
| `-UseDeviceAuthentication`, `-SkipLogin` | | Sign-in behaviour. |

What the script guarantees:

- It creates **no assignment**.
- It publishes the definitions first, then the initiative, and stops before the initiative if any definition fails. Publishing is idempotent, so you can fix the cause (or use `-ExcludePolicy`) and run again.
- It never overwrites a definition or initiative it did not publish: everything it publishes carries `metadata.managedBy = azurethings-alz-policy`, and a name clash with anything else stops the run before any write.
- It retries throttling (HTTP 429/5xx) and checks what Azure stored.

Azure allows 500 policy definitions and 200 initiatives per scope, 400 parameters per initiative, and 64 characters in a definition name. This package uses 93 (or 149) definitions, 1 initiative and 189 (or 256) parameters.

## Assign

Audit everything. No parameters, no managed identity:

```powershell
$scope = '/providers/Microsoft.Management/managementGroups/contoso'
$set = Get-AzPolicySetDefinition -Name alz-custom-policies -ManagementGroupName contoso
New-AzPolicyAssignment -Name alz-audit -DisplayName 'ALZ custom policies (audit)' -Scope $scope -PolicySetDefinition $set
```

Names of assignments at a management group are limited to 24 characters.

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

The import replaces `definitions/`, rewrites [alz-library-source.json](alz-library-source.json) and regenerates [policy-catalog.md](policy-catalog.md). Run `./Deploy-AlzPolicy.ps1` again to publish the update; parameter names of unchanged policies stay the same.

## Validate

`./Test-AlzPolicy.ps1` needs no Azure access. It checks that the imported files match the source manifest, that only the effect handling differs from upstream, that every policy defaults to an audit-mode effect and the initiative needs no input, that parameter names are stable, that the catalog is current, and that the deploy script behaves (fresh deployment, re-run, `-WhatIf`, throttling, name clashes, rejected definitions, subscription scope, cloud filtering, removal) against a simulated Azure Resource Manager.

## Source and licence

The definitions are copied from [Azure/Azure-Landing-Zones-Library](https://github.com/Azure/Azure-Landing-Zones-Library) (MIT, © Microsoft Corporation); the licence is in [LICENSE-Azure-Landing-Zones-Library.txt](LICENSE-Azure-Landing-Zones-Library.txt). Each published definition keeps its upstream `metadata.source` and `version` and adds `alzName` and `alzLibraryVersion`.
