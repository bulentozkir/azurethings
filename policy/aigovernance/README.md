# Azure AI Governance: Audit Control Catalogue

An opinionated, risk-prioritized assessment catalogue derived from Azure landing zones, the Cloud Adoption Framework (CAF), Azure service policy references, Microsoft's Responsible AI guidance, NIST AI RMF, and OWASP's generative AI risks. Sources were reviewed on **2026-09-23**. Controls are included for their risk-reduction and assessment value, not to reach a fixed count. This is a proposed organizational baseline, not an official Microsoft initiative or a certification of regulatory compliance.

Catalogue controls are not one-to-one with deployable Azure Policy definitions. Some controls reuse one parameterized definition; others require several service-specific references. Runtime safety, document permissions, human approvals, and actual spending cannot be guaranteed by an ARM policy. Those controls remain separate evidence-based assessments instead of being represented by nonfunctional policy JSON.

## Audit-Only Contract

**The initiative remains audit-only.** Custom definitions accept `Audit` and `Deny`, with `Audit` as the default. The initiative explicitly binds them to `Audit`, and its built-in references use `Audit` or `AuditIfNotExists`. Supporting Deny in a custom definition does not enable enforcement in this initiative. A separate assignment can explicitly select Deny; there is no automatic remediation or planned promotion of the initiative to enforcement.

The built-in manifest retains Microsoft's `documentedEffects` as reference facts, not permitted assignment choices. Its `assignmentProfile` limits selection to audit effects. `recommendedInitialEffect` is always an audit effect when one exists, and is `null` when no audit effect is supported. B08, B15, and B21 cannot audit; B37 is ineligible for a custom initiative. B02/B03, which require disabled public access, remain excluded. B04/B36/B38/B39/B40 and B41-B55 audit private-endpoint existence independently of public-access configuration: approved-IP public access can coexist with a private endpoint where the service supports both.

The catalogue describes desired states and evidence to review. A matching rule means a finding, not a blocked request. Existing Azure assignments outside this pack are not changed. The deployment script publishes definitions and an initiative at the tenant root management group only. **Assignments remain manual; the script never creates one.**

## What Is Included

- [definitions/allowed-ai-locations.json](definitions/allowed-ai-locations.json): approved ARM resource regions.
- [definitions/allowed-ai-account-kinds.json](definitions/allowed-ai-account-kinds.json): approved Cognitive Services account kinds; the equivalent system built-in is not eligible for a custom initiative.
- [definitions/require-ai-tag.json](definitions/require-ai-tag.json): a required, nonempty governance tag; assign separately for each tag.
- [definitions/allowed-ai-tag-values.json](definitions/allowed-ai-tag-values.json): required tags with approved values.
- [definitions/allowed-model-deployment-skus.json](definitions/allowed-model-deployment-skus.json): approved Cognitive Services model deployment SKUs, including geography choices.
- [definitions/restrict-ai-public-ip-access.json](definitions/restrict-ai-public-ip-access.json): approved IP/CIDR rules and restrictive public-access defaults for Cognitive Services, Search, and ML workspaces.
- [definitions/restrict-ai-virtual-network-rules.json](definitions/restrict-ai-virtual-network-rules.json): approved full subnet IDs for configured Cognitive Services virtual network rules.
- [definitions/restrict-ai-trusted-services.json](definitions/restrict-ai-trusted-services.json): explicit trusted-service bypass approval for Cognitive Services and Search; `allowTrustedServices` defaults to false.
- [definitions/require-ai-private-endpoints.json](definitions/require-ai-private-endpoints.json): supplemental Approved private endpoint existence for ML registries, Video Indexer, Container Apps environments, API Management, MongoDB clusters, and SQL managed instances. Other supported types use built-ins.
- [definitions/require-ai-monitor-private-link-scope.json](definitions/require-ai-monitor-private-link-scope.json): Log Analytics and Application Insights scope membership, paired with B55 for Approved endpoints on the shared Monitor scope.
- [definitions/require-foundry-vnet-injection.json](definitions/require-foundry-vnet-injection.json): customer-subnet agent injection on project-enabled Foundry AIServices accounts, distinct from Private Link and ML managed networking.
- [built-in-references.json](built-in-references.json): documented built-in definition IDs, effects, preview status, and source links. This is a reference manifest, **not** an initiative or assignment.
- [Deploy-AiGovernance.ps1](Deploy-AiGovernance.ps1): reusable tenant-root deployment with live preflight, fixed audit effects, `-WhatIf`, ownership checks, and read-back verification; no assignment creation.
- [Test-AiGovernance.ps1](Test-AiGovernance.ps1): offline structural, catalogue, and focused rule checks. It does not evaluate policies in Azure.

Custom JSON files contain **policy definition properties**, following this repository's convention, not ARM deployment templates. The deployment script wraps them in `properties` for Policy REST requests. The current package registers eleven custom definitions and generates sixteen custom-policy references, including seven tag references. Its 51 audit-capable, eligible built-in definitions generate 65 references: five content-filter definitions are each reused for every supported category. The default initiative therefore contains 81 references from 62 distinct definitions, not one reference per catalogue row. Unimplemented C and external X controls are not represented as deployed policies.

## Built-In First

Use an existing built-in whenever its scope, predicate, supported effect, and custom-initiative eligibility satisfy the requirement. Do not clone a built-in simply to change its display name or parameter defaults. The deployment script checks live schemas, rejects System Policy definitions, and fails on unavailable selected built-ins; it does not silently invent a custom fallback.

The live built-in catalogue was compared on **2026-09-23**. Retained custom definitions address these specific gaps; recheck them as Microsoft adds or updates built-ins:

| Requirement | Built-in reviewed | Why a custom remains |
| --- | --- | --- |
| Approved Cognitive Services account kinds | **Audit - Allowed Cognitive Services Kinds**, `c9623da8-5301-401e-9ca8-69396833b6f3` (B37) | Equivalent predicate, but Azure rejected this System Policy built-in as a member of a custom policy set. The other audit-kind candidate checks a specified list for non-production use, not an approved-kind allowlist. |
| AI-scoped approved locations, including explicitly approving `global` | **Allowed locations**, `e56962a6-4747-49cd-b67b-bf8b01975c4c`, supports Audit | The built-in always exempts `global` and evaluates other resource types in the assigned scope. Replacing the AI-scoped rule would change its coverage. |
| Nonempty `ai-workload` with an Audit default | **Require a tag on resources**, `871b6d14-10aa-478d-b590-94f262ecfa99` | Fixed Deny, no Audit parameter, and checks only existence, so an empty value passes. |
| Each of six AI tags must have one of several allowed values | **Require a tag and its value on resources**, `1e30110a-5ceb-460c-a204-c1c3969c6d62` | Fixed Deny and a single required value, not an allowed-values list. Repeated references would require all values simultaneously, not provide alternatives. |
| Approved Cognitive Services child model-deployment SKUs | Model approval/eligibility built-ins and deployment-SKU alias search | No equivalent built-in for the requested SKU allowlist was found. Model identity or eligibility does not enforce deployment processing geography. |
| Approved IP/CIDR and subnet lists, restrictive defaults, and approved bypass settings | B05, **Azure AI Services resources should restrict network access** | Checks default-deny or presence of Search IP rules, not membership in approved lists or every required service/bypass case. The three custom controls address those distinct gaps. |
| Approved private endpoints for six remaining AI/dependency types | Live catalogue and service aliases | No equivalent built-in was found for ML registries, Video Indexer, Container Apps environments, API Management, MongoDB clusters, or SQL managed instances. All other direct endpoint checks reuse B04/B36/B38/B39/B40 and B41-B55 instead of custom copies. |
| Monitor scope membership on Log Analytics and Application Insights | B55 and a live rule search for both resource types | B55 checks existing scopes, not telemetry resources that were never linked to one. The supplemental membership rule closes that gap; it does not claim to validate a remote scope's endpoint. |
| Foundry customer-subnet agent injection | Live catalogue search for `networkInjections` | No matching built-in was found. Private Link and ML managed-network isolation do not verify the Foundry injection field. |

On 2026-09-23, Azure returned `InvalidCreatePolicySetDefinitionRequest` when B37 was referenced: the built-in "can not be part of a custom policy set." B37 remains in the manifest as excluded evidence, not as a deployed reference. A matching rule alone is therefore insufficient to establish a usable replacement. Fixed-effect built-ins receive no fabricated `effect` parameter. Adding Deny as an option to custom definitions does not justify substituting Deny-only built-ins into the audit-only initiative or relying on manual assignment overrides to make it safe.

## Deploy the Initiative

Run in **PowerShell 7 with Az.Accounts installed**. Keep the script with this folder's definitions and manifest; it is not a standalone file with embedded policy rules. The signing-in identity needs permission to read the tenant root management group and create/update policy definitions and policy set definitions there, for example an appropriately scoped Resource Policy Contributor role plus management-group read access. Subscription ownership alone does not grant root-level permissions. The script does not elevate permissions or create role assignments.

```powershell
$deploymentParameters = @{
	TenantId = '<customer-tenant-guid>'
	SubscriptionId = '<customer-subscription-guid>'
	InitiativeName = 'ai-governance-audit'
	DefinitionPrefix = 'ai-gov'
}

& ./policy/aigovernance/Deploy-AiGovernance.ps1 @deploymentParameters -WhatIf
$result = & ./policy/aigovernance/Deploy-AiGovernance.ps1 @deploymentParameters
$result.InitiativeId
$result.AssignmentParameters | Format-Table
```

The tenant GUID identifies its root management group. The script reads that group and verifies its tenant and parent before writing. **`SubscriptionId` selects the authentication context and the provider-alias discovery scope; it is not the deployment scope.** All definition writes are under `/providers/Microsoft.Management/managementGroups/<TenantId>`.

| Script parameter | Required / default | Purpose |
| --- | --- | --- |
| `TenantId` | Required GUID | Customer's Entra tenant and root management-group identifier. |
| `SubscriptionId` | Required GUID | An accessible subscription in that tenant for sign-in and provider-alias checks. |
| `InitiativeName` | `ai-governance-audit` | Initiative resource name at the tenant root. |
| `DefinitionPrefix` | `ai-gov` | Prefix for the custom policy names. Change both prefix and initiative name when publishing a separate copy. |
| `DisplayName` | `Azure AI Governance - Audit Only` | Portal display name. |
| `ExcludeBuiltInReference` | Empty string array | Explicit additional exclusions, using manifest IDs such as `B22`. Reduces assessment coverage and is recorded in initiative metadata; it does not re-enable baseline exclusions. |
| `UseDeviceAuthentication` | Switch, off | Use Az device-code sign-in when a matching Az context is not already available. Complete authentication directly with Microsoft; never share tokens or codes in chat. |
| `SkipLogin` | Switch, off | Reuse a matching authenticated Az context; fail rather than prompt when the tenant/subscription is wrong. Useful for an already-authenticated automation session. |
| `WhatIf` | Standard switch, off | Perform live reads and show the planned definition publication without issuing writes. Authentication and read permissions are still required. |

The script checks every selected built-in's actual effect parameter, including `effects` and `audit_effect` where used, and validates custom field aliases. B43's unused deprecated `effect` is also fixed to Audit through the manifest's `fixedParameters`, not exposed as an assignment choice. Missing built-ins or unsupported audit effects fail preflight rather than being silently skipped. It refuses to overwrite same-named resources without this package's ownership marker. A rerun updates package-owned definitions; publication is not transactional, so a service error can leave some definitions created. Rerun after correcting the reported issue; the script does not delete resources on failure.

The former combined public-access reference `AI_Network` is replaced by `AI_PublicIPs`, `AI_VirtualNetworkRules`, and `AI_TrustedServices`. The `allowedIpRules` and `allowedSubnetIds` initiative parameter names are preserved; the new `allowTrustedServices` parameter defaults to false. The retired combined Azure definition is not republished or referenced, but the script does not delete it automatically because other assignments or initiatives might still use it. Review any reference-specific exemptions or overrides when updating an existing assignment.

### Manual Assignment

In Azure Policy, select the root management group under **Definitions**, locate **Azure AI Governance - Audit Only**, and create an assignment at your chosen scope. Publishing a definition at the root makes it reusable below that root; it does not automatically assess every subscription.

| Initiative parameter | Value to provide or review during assignment |
| --- | --- |
| `allowedLocations` | Customer-approved ARM resource regions. Required; no invented default. |
| `allowedKinds` | Approved Cognitive Services account kinds. Required. |
| `allowedDeploymentSkus` | Approved regional/Data Zone/Global deployment SKUs. Required. |
| `allowedIpRules` | Approved public IPv4/CIDR rule strings. Required; `[]` means no IP exceptions are considered compliant. |
| `allowedSubnetIds` | Approved full Cognitive Services subnet IDs. Required; `[]` means no subnet exceptions are considered compliant. |
| `allowTrustedServices` | Defaults to `false`. Set `true` only to permit the service-defined `AzureServices` bypass. It neither enables nor requires bypass. |
| `locationResourceTypes` | Defaults to the 44 location-bearing types described below, including shared hosting/data services. Narrow the list or assignment scope where those resources are not AI-owned. Explicit lists already saved in assignments are not automatically expanded. |
| `tagResourceTypes` | Still defaults to the five core AI parent types. Location expansion does not automatically impose the seven AI tags on every shared dependency. |
| `B18_allowedPublishers`, `B18_allowedAssetIds`, `B20_allowedPublishers`, `B20_allowedAssetIds` | Review model-approval lists; publisher approval can be broader than asset approval. Inspect live defaults rather than assuming the example catalogue is an approved-model list. |
| `B19_onlyAllowDirectFromAzure`, `B19_denyPreviewModels` | Review model eligibility; false/false imposes no eligibility requirement. Both remain audit-only regardless of the toggle names. |
| `B26_entityKind`, `B27_entityKind` | Required JSON arrays of the exact agent `entityKind` values to assess. These are targeting lists, not account kinds or ARM resource types. The Microsoft built-ins publish no allowed-values list or default. `[]` skips all agents; `"*"` is a literal, not a wildcard. Use the same verified list in both fields when both policies should assess the same agents. |
| `B22_filterName`, `B23_filterName`, `B24_filterName`, `B26_filterName`, `B27_filterName` | Unused compatibility fields with defaults. Saved initiative parameters cannot be deleted; all filter categories now have fixed built-in references. Changing these legacy fields does not change coverage. They need no input and are normally absent when the portal shows only parameters needing input. |
| `B31_logAnalytics` | Required approved Log Analytics workspace resource ID. This audits the destination; it does not deploy diagnostic settings. |
| `B42_excludedManagedByResourceProviders` | Defaults to `[]`, assessing every storage account in scope. Add managed-service exclusions only after accepting and documenting the resulting coverage reduction. |
| Other `Bxx_*` parameters | Lifted from live built-in schemas, preserving types and defaults. Review severity, enabled/blocking settings, retention, logging categories, and applicability for the customer. |

Effects are fixed in the initiative reference mappings or in the built-in itself, not exposed as initiative assignment parameters. The custom definitions offer `Audit` and `Deny` for separate direct assignments, defaulting to `Audit`; the generated initiative continues to use `Audit`. Deny blocks noncompliant create/update requests; it does not repair existing resources or directly filter live network traffic. There is no `Assign` switch, remediation identity, or automatic permission assignment. The seven tag names and their vocabulary are fixed in the generated references; only `ai-workload` content is free-form.

### Assignment Input Format

Each built-in parameter label identifies its policy family and reference ID. Tooltips explain its scope, expected input, and array syntax; the live built-in's types, choices, resource pickers, and defaults are preserved except for the explicitly documented compatibility fields. The default initiative has **eight required inputs**: five customer allowlists, two agent-kind arrays, and the diagnostic Log Analytics destination.

For a free-form Array parameter, select the custom-array editor (`...`) and enter a JSON array of double-quoted strings. A bare string, unquoted items, or comma-separated text without brackets is not valid. For example, `["westeurope","northeurope"]` is valid location-array syntax. Use your approved values, not documentation examples.

**Entity Kind is deliberately still required.** The agent policies evaluate `Microsoft.CognitiveServices.Data/accounts/projects/agents/entityKind` with exact list membership. They do not evaluate the parent account's `kind`, nor do they infer every agent kind when the list is empty. The syntax is `["<verified-entity-kind>"]`, replacing the placeholder with the actual service-reported value. Neither the live schemas nor the referenced policy documentation provide a verified universal enum; the generator does not guess `Agent`, `prompt`, `hosted`, or another value and risk silently missing agents. A syntactically valid value that does not match any agent also produces no agent findings.

Array parameters with `allowedValues` already support multiple choices. For enabled/blocking settings, the built-ins use the **strings** `"true"` and `"false"`; JSON `["true"]` differs from `[true]`. Accepting both strings permits either stored setting. These inputs describe the configuration that the audit regards as compliant; they do not make this initiative block resource writes or change model filtering.

### Content Filter Coverage

Microsoft's five filtering built-ins accept a **single String** `filterName`; passing an Array would violate their contracts. The manifest's `expandByParameter` reuses each existing built-in once per live allowed category instead of cloning it or changing its parameter type. Every generated reference remains **Audit**, with no conditional Disabled effect. Thus all categories below are assessed, rather than presenting a misleading multi-select bound to a scalar input.

| Policy family | Categories audited independently | Shared settings |
| --- | --- | --- |
| B22: model deployment prompts | Profanity; Jailbreak; Indirect Attack; Indirect Attack Spotlighting | B22 enabled and blocking values. |
| B23: model deployment responses | Profanity; Protected Material Code; Protected Material Text | B23 enabled and blocking values. |
| B24: model deployment harmful content | Hate; Sexual; Violence; Selfharm | B24 prompt/response severity, enabled, and blocking values. |
| B26: agent prompts | Profanity; Jailbreak; Indirect Attack; Indirect Attack Spotlighting | B26 entity kinds, enabled, and blocking values. |
| B27: agent harmful content | Hate; Sexual; Violence; Selfharm | B27 entity kinds, severity, enabled, and blocking values. |

These five families generate **19 category-specific references**, replacing five one-category references. B25 remains the separate streaming-mode audit. The original reference ID is retained for each family's first category; the other references have deterministic suffixes such as `B22_Jailbreak` and `B24_Selfharm`. Review existing reference-specific exemptions, overrides, and noncompliance messages before relying on them after this update: a former exemption for B22 does not automatically cover its new sibling references. Existing assignment parameter values are not rewritten, and the five compatibility selector values no longer control coverage.

Per-assignment multi-select with skipped categories would require conditional `Disabled` effects or a separate initiative profile. This package retains the explicitly requested fixed-Audit contract instead. Exempt categories only through the customer's reviewed exemption process; do not use an empty agent-kind array as a shortcut. The controls remain Preview, and all-category configuration findings are not proof of model/runtime support or effective content filtering.

After the initiative definition is updated, close and reopen the assignment form so Azure Portal reloads its parameter metadata. No assignment is created by this package. See [initiative parameter structure](https://learn.microsoft.com/azure/governance/policy/concepts/initiative-definition-structure#parameters), [saved initiative parameter limitations](https://learn.microsoft.com/azure/governance/policy/tutorials/create-and-manage#create-and-assign-an-initiative-definition), and [array parameter syntax](https://learn.microsoft.com/azure/governance/policy/how-to/author-policies-for-arrays#parameter-arrays).

Read-back verification on **2026-09-23** confirmed the updated tenant-root initiative: eleven active custom definitions, 51 built-in definitions, and 81 policy references from 62 distinct definitions (**68 Audit, 13 AuditIfNotExists**). Azure stored 49 distinct parameter labels, eight required inputs, and 19 fixed-Audit category checks across the five content-filter families. Existing parameter names and types were preserved; the five obsolete single-filter selectors have optional compatibility defaults. The connectivity table still accounts for all 44 location types plus the shared Monitor scope; 27 endpoint-owning types have direct Approved-connection checks. Trusted-service bypass still defaults to disallowed. No assignment was created or modified. The former combined network definition remains stored in Azure but is not referenced by this initiative. Definition acceptance is separate from resource-level compliance evaluation and network testing after assignment.

## Coverage and Boundaries

| Resource family | Coverage and important boundary |
| --- | --- |
| Microsoft Foundry and Azure OpenAI | `Microsoft.CognitiveServices/accounts`, account projects, and model deployments. Account, project, deployment, and agent controls are not interchangeable. |
| Foundry Tools / Azure AI services | Includes supported Speech, Vision, Language, Translator, Document Intelligence, and Content Safety account kinds. Feature and policy support varies by kind, SKU, API version, and cloud. |
| Azure Machine Learning and hub-based Foundry | `Microsoft.MachineLearningServices/workspaces`, including applicable Hub/Project kinds, registries, compute, and inference endpoints. These are different from Cognitive Services-based Foundry projects. |
| Azure AI Search and grounding | Search services plus indexes, indexers, skillsets, knowledge sources, and document permissions. Much of the latter is data-plane configuration. |
| Agents, tools, and bots | Foundry agents, MCP/tool connections, agent identity and memory, and `Microsoft.BotService/botServices`. ARM resource inventory alone is not an agent inventory. |
| Self-hosted AI | AKS, Container Apps, App Service/Functions, GPU VMs, and Azure Databricks. Apply the host platform's controls as well as model/application controls. |
| AI dependencies | The location list includes common Storage, Key Vault, Container Registry, databases, API Management, Monitor, and Purview resources. This does not make every other AI policy applicable to those shared services. |
| Outside ARM governance | Entra tenant settings, Fabric workspace/item residency, Copilot Studio, external model providers, and SaaS require their own controls. Auditing a Fabric capacity ARM location does not govern every Fabric item's data processing. |

### Location Coverage

The location definition now lists **44 exact ARM types**. The list was checked against live provider metadata and the [documented ML compute schema][MLCompute] on 2026-09-23. `All` mode is used with this explicit list so location-bearing ML children are not skipped merely because tag/indexing metadata is absent. It is not a namespace wildcard or a claim to cover every future resource type. The two tag definitions remain `Indexed` and retain their smaller default scope.

| Family | Included ARM types |
| --- | --- |
| Foundry, OpenAI, Speech, Vision, Language, Translator, Document Intelligence, Content Safety | `Microsoft.CognitiveServices/accounts` and `Microsoft.CognitiveServices/accounts/projects`. Account kinds share the parent type; model deployments use separate SKU/geography checks. |
| ML workspaces, AI hubs, hub projects, and registries | `Microsoft.MachineLearningServices/workspaces`, `Microsoft.MachineLearningServices/registries`. Hub and Project are workspace kinds, not separate provider types. |
| ML compute and inference | `Microsoft.MachineLearningServices/workspaces/computes`, `.../onlineEndpoints`, `.../onlineEndpoints/deployments`, `.../batchEndpoints`, `.../batchEndpoints/deployments`, `.../serverlessEndpoints`. All shortened paths begin with `Microsoft.MachineLearningServices/workspaces`. |
| Search, bots, video, health AI | `Microsoft.Search/searchServices`, `Microsoft.BotService/botServices`, `Microsoft.VideoIndexer/accounts`, `Microsoft.HealthBot/healthBots`, `Microsoft.HealthDataAIServices/deidServices`. |
| AI hosting and training | `Microsoft.Databricks/workspaces`, `Microsoft.ContainerService/managedClusters`, `Microsoft.Compute/virtualMachines`, `Microsoft.Compute/virtualMachineScaleSets`, `Microsoft.App/containerApps`, `Microsoft.App/managedEnvironments`, `Microsoft.App/jobs`, `Microsoft.ContainerInstance/containerGroups`, `Microsoft.Web/sites`, `Microsoft.Web/serverfarms`, `Microsoft.Batch/batchAccounts`. Functions share `Microsoft.Web/sites`. |
| Artifacts and keys | `Microsoft.Storage/storageAccounts`, `Microsoft.ContainerRegistry/registries`, `Microsoft.KeyVault/vaults`, `Microsoft.KeyVault/managedHSMs`. |
| Grounding and vector data | `Microsoft.DocumentDB/databaseAccounts`, `Microsoft.DocumentDB/mongoClusters`, `Microsoft.DBforPostgreSQL/flexibleServers`, `Microsoft.Sql/servers`, `Microsoft.Sql/managedInstances`, `Microsoft.Cache/redis`, `Microsoft.Cache/redisEnterprise` (including Azure Managed Redis). |
| Gateways, pipelines, governance, telemetry | `Microsoft.ApiManagement/service`, `Microsoft.Synapse/workspaces`, `Microsoft.DataFactory/factories`, `Microsoft.Fabric/capacities`, `Microsoft.Purview/accounts`, `Microsoft.OperationalInsights/workspaces`, `Microsoft.Insights/components`. |

**Shared types are evaluated whether or not a particular instance runs AI.** Use an AI workload assignment scope or override `locationResourceTypes` to avoid auditing unrelated VMs, Storage, databases, and apps. Use the built-in Allowed locations for whole-estate placement where its global exemption and broader scope meet the requirement.

This rule checks top-level ARM `location` only. It does not validate ML `computeLocation`, attached compute's actual region, registry or database replica regions, Storage secondary regions, APIM additional locations, Global/Data Zone processing, agent tool destinations, or SaaS data residency. Locationless descendants such as Cognitive Services model deployments are deliberately excluded. Resource placement and processing geography remain different controls.

## AI Tag Baseline

Use only the following AI tag set in this baseline. The supplied screenshots contain **seven tags**: one workload identifier and six controlled vocabularies. These replace the earlier owner, classification, environment, and cost-allocation tag suggestions; those additional tags are not required by this pack.

| Tag | Values | Meaning |
| --- | --- | --- |
| `ai-workload` | Any nonempty workload identifier, for example `support-chatbot` | Groups the AI service and its supporting Storage, Search, application, and gateway resources. |
| `ai-role` | `model`, `search`, `data`, `app`, `gateway` | What the resource does in the AI solution. |
| `ai-usage` | `inference`, `training`, `fine-tuning`, `mixed` | Whether the workload runs models, develops them, or does both. |
| `ai-audience` | `internal`, `customer`, `public`, `mixed` | Who uses the AI solution. |
| `ai-sharing` | `dedicated`, `shared` | Whether the resource serves one workload or several. |
| `ai-autonomy` | `read-only`, `approval-required`, `autonomous` | Whether the AI provides answers or can take actions. |
| `ai-risk` | `low`, `medium`, `high` | The team's rating of potential harm if the AI gets things wrong. |

The generated initiative uses one reference to [definitions/require-ai-tag.json](definitions/require-ai-tag.json) with `tagName=ai-workload`, and six references to [definitions/allowed-ai-tag-values.json](definitions/allowed-ai-tag-values.json), each with its own `tagName`, `allowedTagValues`, and unique initiative reference ID. The value-checking policy already checks missing and empty tags; no duplicate presence-only references are added for those six tags. These are initiative mappings, not assignments.

Keep workload identifiers free-form; `support-chatbot` is an example, not the only permitted workload. Use the lowercase spellings shown for consistency. Azure Policy's `in`/`notIn` comparisons do not enforce case-sensitive tag value spelling. A `public` audience tag does not permit unrestricted networking, and an `autonomous` tag does not grant tool permissions. Tags describe the declared design; they do not prove actual behavior or risk.

To assess supporting Storage, application, or gateway resources, include their tag-capable resource types in the tag policies' `resourceTypes` parameter and assign at the AI workload's scope. Do not require a pre-existing `ai-workload` tag to enter that scope, or untagged resources would evade the missing-tag audit. For shared infrastructure, agree a shared-workload identifier and track its consuming workloads in inventory; a scalar tag is not a many-to-many relationship model.

## Public Access Baseline

**The desired configuration limits public access to approved IP addresses or networks; it does not universally disable it.** Three independent policies report which part is noncompliant:

| Check | Initiative inputs and scope |
| --- | --- |
| Public IPs and firewall defaults (`AI_PublicIPs`) | `allowedIpRules`; Cognitive Services, Search, and ML workspaces. Checks enabled public access, approved IP/CIDR membership, and restrictive defaults. |
| Configured VNet rules (`AI_VirtualNetworkRules`) | `allowedSubnetIds`; Cognitive Services only. Checks each configured subnet ID, including dormant rules. Does not require a VNet rule when IP/private access is used. |
| Trusted-service bypass (`AI_TrustedServices`) | `allowTrustedServices`; Cognitive Services and Search. Default false requires no AzureServices bypass; true permits it without changing the resource. |

The controls are complementary. An approved IP does not approve an added VNet rule or a trusted-service exception. VNet rule allowlisting is not Foundry VNet injection: the former permits inbound traffic from a configured subnet, while the latter configures the agent's network integration.

| Service | Public-access requirements |
| --- | --- |
| Cognitive Services / Foundry / OpenAI | Explicit `publicNetworkAccess=Enabled`, `networkAcls.defaultAction=Deny`, approved IP/CIDR and subnet rules, and `bypass=None` unless trusted services are explicitly approved. Empty IP rules with default Deny are valid for VNet-only or private access. |
| AI Search | Explicit public access enabled, an approved bypass setting, and a nonempty IP rule list containing only approved values. Search has no equivalent subnet-ID rule list. An empty public IP list allows all public sources, so it produces an IP-policy finding. |
| ML workspace / applicable hub | Explicit public access enabled, `networkAcls.defaultAction=Deny`, and every IP rule approved. Empty rules with default Deny grant no public access. Test each workspace kind and endpoint path separately. |

Supply `allowedIpRules` and `allowedSubnetIds` at assignment time. They have no organization-specific defaults. Use full subnet resource IDs; an empty approved list makes every exception of that type noncompliant. IP/CIDR comparisons are **literal membership**, not subnet containment: approve the exact normalized strings the provider stores, including any `/32` notation. Rules covering `/0` or a wildcard are reported even if mistakenly included in the approved list. Review combined ranges to avoid accidentally approving the entire internet through several broad rules.

`publicNetworkAccess=Disabled` satisfies the public-IP check, but configured unapproved VNet rules and unapproved trusted-service bypass still generate their own findings. For enabled Cognitive Services/Search public access, configure `bypass=None` explicitly or approve `AzureServices` with `allowTrustedServices=true`. The latter bypasses IP rules for service-defined trusted callers and needs separate identity/RBAC review. ML workspaces have no corresponding bypass field in this policy. Subnet existence, ownership, DNS, service endpoints, and connectivity remain separate checks. Network Security Perimeter modes need a separately reviewed profile.

ML's selected-IP configuration is documented as a **post-creation** operation and requires compatible workspace/compute network isolation. Audit can therefore report an interim finding during onboarding until the selected-IP configuration is complete; it does not block provisioning. The policy checks resource configuration, not the actual source IP of a live request. Use the client's public IPv4 egress address, not an on-premises private address, for IP rules. Service data-plane firewalls do not replace ARM management-plane authorization.

B02/B03 (disable public access) remain excluded. Private-endpoint-existence audits are included separately: approved-IP public access can remain enabled where the service permits coexistence, but does not satisfy the requirement to have an Approved private connection. The expanded initiative also assesses private endpoints on supported shared dependencies; the three selected-public-access policies still retain their own service-specific scope. See [Cognitive Services networking][CognitiveNetwork], [Search firewall][SearchNetwork], and [ML selected IP access][MLNetwork]. Confirm service-specific aliases in the target cloud before deployment.

## Private Connectivity

Private endpoint existence and Foundry VNet injection are separate from the three public-access controls. Neither proves end-to-end isolation or automatically disables a public endpoint.

**Include a resource type only when private-endpoint existence can be evaluated through a supported, assignable built-in or verified service-specific Azure Policy aliases.** Private Link product support alone is insufficient if the policy surface is unavailable. Do not copy the broader location list into this scope, invent missing endpoint properties, or flag an unsupported service for lacking a feature it cannot expose.

Twenty reused built-ins plus the supplemental endpoint definition check Approved connections on **27 endpoint-owning ARM types**: 26 from the 44-type location list, plus the shared Azure Monitor Private Link Scope. A separate custom check covers scope membership for the two telemetry types. The table accounts for every location type, including boundaries and limitations rather than pretending all 44 own a private endpoint. This is a reviewed list, not coverage of every future Azure resource type.

### Private Connectivity Coverage

`AI_PrivateEndpoints` is the six-type supplemental custom rule. `AI_MonitorPrivateLinkScope` checks telemetry membership only. All B references are reused built-ins. **Shared resources are evaluated regardless of whether they currently host AI.** Narrow the assignment scope or use reviewed exemptions; changing `locationResourceTypes` does not change private-connectivity scope.

| Resource type | Assessment | Reference / boundary |
| --- | --- | --- |
| `Microsoft.CognitiveServices/accounts` | Endpoint | B04: Foundry, OpenAI, and supported Speech, Vision, Language, Translator, Document Intelligence, Content Safety and other account kinds. |
| `Microsoft.CognitiveServices/accounts/projects` | Shared boundary | B04 at the Foundry account; no independent project endpoint check. |
| `Microsoft.MachineLearningServices/workspaces` | Endpoint | B36: ML workspaces and applicable Hub/Project kinds; B06 separately assesses managed networking. |
| `Microsoft.MachineLearningServices/workspaces/computes` | Related | B07 checks compute VNet placement; B36 checks the workspace, not individual compute endpoints. |
| `Microsoft.MachineLearningServices/workspaces/onlineEndpoints` | Shared boundary | B36 at the workspace; scoring-path public access and outbound isolation need separate validation. |
| `Microsoft.MachineLearningServices/workspaces/onlineEndpoints/deployments` | Shared boundary | Workspace endpoint check through B36 does not prove deployment runtime isolation. |
| `Microsoft.MachineLearningServices/workspaces/batchEndpoints` | Shared boundary | B36 at the workspace; batch compute and data paths need separate validation. |
| `Microsoft.MachineLearningServices/workspaces/batchEndpoints/deployments` | Shared boundary | No independent connection alias was verified; B36 checks only the workspace. |
| `Microsoft.MachineLearningServices/workspaces/serverlessEndpoints` | Shared boundary | No independent connection alias was verified; B36 is not proof of serverless inference isolation. |
| `Microsoft.MachineLearningServices/registries` | Endpoint | AI_PrivateEndpoints: accepts an Approved connection in either current or legacy registry collection. |
| `Microsoft.Search/searchServices` | Endpoint | B04; B33 separately audits Private Link-capable SKUs. |
| `Microsoft.BotService/botServices` | Endpoint | B39; bot application hosting and channel connectivity remain separate. |
| `Microsoft.VideoIndexer/accounts` | Endpoint | AI_PrivateEndpoints. |
| `Microsoft.HealthBot/healthBots` | Unsupported | Published security baseline lists Private Link as unsupported; not a compliant-result claim. |
| `Microsoft.HealthDataAIServices/deidServices` | Endpoint | B38. |
| `Microsoft.Databricks/workspaces` | Endpoint | B40; B56 separately checks workspace VNet-injection parameters, not serverless compute placement. |
| `Microsoft.ContainerService/managedClusters` | Related | B57 checks private API-server configuration, not an Approved connection collection or workload ingress. |
| `Microsoft.Compute/virtualMachines` | Not direct | No native per-VM service endpoint to require. VNet/NIC/NSG and any application Private Link Service need separate controls. |
| `Microsoft.Compute/virtualMachineScaleSets` | Not direct | Same boundary as VMs; a scale set does not own a native PaaS private endpoint. |
| `Microsoft.App/containerApps` | Shared boundary | AI_PrivateEndpoints at the associated managed environment, not per application. |
| `Microsoft.App/managedEnvironments` | Endpoint | AI_PrivateEndpoints; Private Link requires a workload-profiles environment and disabled public network access. |
| `Microsoft.App/jobs` | Shared boundary | AI_PrivateEndpoints checks the environment, not job execution or its outbound connections. |
| `Microsoft.ContainerInstance/containerGroups` | Not direct | Use VNet deployment and application-level networking; no native group connection collection was verified. |
| `Microsoft.Web/sites` | Endpoint | B51: Web Apps and applicable Function Apps; hosting-plan support and slots require review. |
| `Microsoft.Web/serverfarms` | Shared boundary | B51 assesses hosted sites. App Service plans do not own app private endpoints. |
| `Microsoft.Batch/batchAccounts` | Endpoint | B50; each required Batch subresource still needs connectivity validation. |
| `Microsoft.Storage/storageAccounts` | Endpoint | B42; no managed-service exclusions by default. One Approved connection does not cover every storage subresource. |
| `Microsoft.KeyVault/vaults` | Endpoint | B43; active and deprecated effect parameters fixed to Audit. |
| `Microsoft.KeyVault/managedHSMs` | Endpoint | B44, Preview. |
| `Microsoft.ContainerRegistry/registries` | Endpoint | B41; Private Link requires Premium. |
| `Microsoft.DocumentDB/databaseAccounts` | Endpoint | B45; no duplicate custom account rule. |
| `Microsoft.DocumentDB/mongoClusters` | Endpoint | AI_PrivateEndpoints; distinct from Cosmos DB databaseAccounts. |
| `Microsoft.DBforPostgreSQL/flexibleServers` | Endpoint | B46; VNet-integrated private-access designs need an explicit applicability review. |
| `Microsoft.Sql/servers` | Endpoint | B47 at the logical server. |
| `Microsoft.Sql/managedInstances` | Endpoint | AI_PrivateEndpoints; the built-in logical-server check does not cover this type. |
| `Microsoft.Cache/redis` | Endpoint | B48; VNet injection is a different networking design. |
| `Microsoft.Cache/redisEnterprise` | Endpoint | B49; includes Azure Managed Redis resources using this ARM type. |
| `Microsoft.ApiManagement/service` | Endpoint | AI_PrivateEndpoints: inbound gateway only; tier and VNet-mode limitations apply. |
| `Microsoft.Synapse/workspaces` | Endpoint | B52: inbound workspace connections, not outbound managed private endpoints. |
| `Microsoft.DataFactory/factories` | Endpoint | B53: inbound factory connections, not integration-runtime outbound access. |
| `Microsoft.Fabric/capacities` | External | Fabric tenant/workspace Private Link is not an endpoint property on an ARM capacity; assess through Fabric administration and connectivity evidence. |
| `Microsoft.Purview/accounts` | Endpoint | B54; one account connection does not prove all portal, ingestion, or scan paths. |
| `Microsoft.OperationalInsights/workspaces` | Membership | AI_MonitorPrivateLinkScope plus B55 on the associated Monitor scope. |
| `Microsoft.Insights/components` | Membership | AI_MonitorPrivateLinkScope plus B55 on the associated Monitor scope. |
| `Microsoft.Insights/privateLinkScopes` | Endpoint | B55: shared endpoint-owning resource for telemetry; included in addition to the location list. |

### Connectivity Limits

Missing, empty, Pending, Rejected, or Disconnected connections do not satisfy an Approved-endpoint check. Disabled public access alone does not satisfy it either. Connection presence does not prove DNS, routing, provisioning success, every subresource, runtime traffic, or approved network ownership. Individual Cognitive Services model deployments use the account boundary; they are not given fictional endpoint properties.

Private Link availability varies by SKU, networking mode, region, and cloud. The existence checks intentionally report absence; they do not silently treat other private-network designs as equivalent. Before assignment, review unsupported plans and alternative designs with resource owners and record appropriate exemptions. In particular, [Container Apps][ContainerAppsPrivateLink] requires workload-profiles environments; classic VNet-injected [API Management][ApiManagementPrivateLink] instances do not support inbound Private Link, and not every tier supports it; VNet-integrated [PostgreSQL flexible servers][PostgreSqlPrivateLink] cannot add Private Link; and SQL managed instances already have VNet-local access, which is not the same as a private endpoint.

[Azure Monitor][MonitorPrivateLink] requires both a recorded telemetry-to-scope association and an Approved connection on that scope. The two checks produce separate findings and do not join across resource IDs. Include the telemetry resources and their centrally hosted scope in the assignment; an out-of-scope or exempt scope is an explicit assurance gap. Service-recorded association fields may lag creation. [Fabric][FabricPrivateLink] needs tenant/workspace administration evidence, and [Health Bot][HealthBotNetwork] remains unsupported; neither is reported as protected by a made-up ARM endpoint test.

**VNet injection:** the separate Foundry rule targets `Microsoft.CognitiveServices/accounts` with `kind=AIServices` and `allowProjectManagement=true`. It requires a `networkInjections[*]` entry with `scenario=agent`, a nonempty `subnetArmId`, and `useMicrosoftManagedNetwork` not true, all on the same entry. This checks **customer-subnet injection**, not Microsoft-managed networking. OpenAI-only accounts and legacy ML hubs are outside this rule; B06/B07 cover the different ML network designs. Databricks uses the separate B56 built-in to check for customer VNet and subnet parameters; that does not establish serverless compute injection. None of these checks proves subnet delegation, ownership, DNS, or actual runtime connectivity.

All references use Audit or AuditIfNotExists. Standalone Deny assignments for endpoint existence or Monitor membership can block creation before the corresponding connection or association can be established; test lifecycle sequencing and exceptions before using them. No endpoint, network setting, assignment, or remediation is created by this pack.

[ContainerAppsPrivateLink]: https://learn.microsoft.com/azure/container-apps/how-to-use-private-endpoint
[ApiManagementPrivateLink]: https://learn.microsoft.com/azure/api-management/private-endpoint
[PostgreSqlPrivateLink]: https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private-link
[MonitorPrivateLink]: https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-security
[FabricPrivateLink]: https://learn.microsoft.com/fabric/security/security-private-links-overview

## Reading the Catalogue

- **P0**: highest-priority assessments for sensitive or production workloads.
- **P1**: next hardening and operational baseline.
- **P2**: maturity, efficiency, and lifecycle improvements.
- **L**: local custom definition included; `Audit` is the default and `Deny` is available for explicit use outside this audit-only initiative.
- **Bxx**: verified documentation reference in the built-in manifest. Select only the audit effect and honor the manifest's exclusions. A reference is not an installed assignment.
- **C**: audit implementation candidate, not supplied. First look for an audit-capable built-in; otherwise verify aliases and API behavior before implementing an audit definition. Candidate coverage is not a verified capability.
- **X**: assessment needs identity, application, gateway, CI/CD, data-plane, or operational evidence outside ordinary ARM Azure Policy. The listed runtime mechanisms are desired controls, not actions deployed by this audit pack.
- **G**: the control is directly supported by the cited guidance. **D**: a recommended deduction or organizational choice based on that guidance, not a quoted framework requirement.

IDs are identifiers grouped by domain, not a numerical ranking or a required consecutive sequence. Merged controls leave gaps; new controls receive unused IDs. Prioritize actionable findings: resource/processing geography (001, 010), public access (011, 104, 105), private endpoints (014), Foundry injection (103), keyless access (021-023), model approval (041), safety (051, 055), RAG authorization (039), tool approval (062), and diagnostics (071).

## 1. Organization and Residency

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-001 | P0 | Audit approved ARM regions for AI services and common dependencies. | Covers 44 explicit location-bearing types; includes shared resources in scope but does not constrain processing or replication geography. | L: allowed-ai-locations | D [CAF] |
| AI-GOV-002 | P1 | Audit approved Cognitive Services account kinds. | Identify unreviewed AI service adoption; account kind is not a model or capability allowlist. | L: allowed-ai-account-kinds; B37 cannot join a custom initiative | D [CAF] |
| AI-GOV-003 | P1 | Audit a nonempty `ai-workload` identifier on AI resources. | Relate the AI service to supporting resources and workload inventory without prescribing a workload name. | L: require-ai-tag; `tagName=ai-workload` | D [CAF] |
| AI-GOV-004 | P1 | Audit the resource's `ai-role`. | Distinguish model, search, data, app, and gateway resources within a solution. | L: allowed-ai-tag-values; `tagName=ai-role` | D [CAF] |
| AI-GOV-005 | P1 | Audit the declared `ai-risk` rating. | Route low, medium, and high risk through the appropriate review; a tag is not a risk assessment. | L: allowed-ai-tag-values; `tagName=ai-risk` | D [NIST] [RAI] |
| AI-GOV-006 | P1 | Audit the declared `ai-usage`. | Distinguish inference, training, fine-tuning, and mixed use for assessment and cost analysis. | L: allowed-ai-tag-values; `tagName=ai-usage` | D [CAF] |
| AI-GOV-007 | P1 | Audit the declared `ai-sharing` model. | Identify dedicated versus shared resources and review isolation and cost attribution accordingly. | L: allowed-ai-tag-values; `tagName=ai-sharing` | D [CAF] |
| AI-GOV-101 | P1 | Audit the declared `ai-audience`. | Identify internal, customer, public, or mixed use without treating the label as an access grant. | L: allowed-ai-tag-values; `tagName=ai-audience` | D [CAF] [Agents] |
| AI-GOV-102 | P1 | Audit the declared `ai-autonomy` level. | Distinguish read-only, approval-required, and autonomous behavior; verify actual permissions separately. | L: allowed-ai-tag-values; `tagName=ai-autonomy` | D [Agents] [NIST] |
| AI-GOV-008 | P0 | Separate production, sandbox, and sensitive-data AI environments. | Prevent development permissions and experimental models from crossing production data boundaries. | X: management-group/subscription design, RBAC, and distinct assignments | G [ALZ] |
| AI-GOV-009 | P0 | Assess ML registry replication against approved locations. | A registry's home location does not constrain all replicated model artifacts. | C: verify registry replication aliases and audit unapproved replicas | D [CAF] |
| AI-GOV-010 | P0 | Allow only approved model deployment SKUs and processing geographies. | Global, Data Zone, and regional deployments have different processing boundaries; choose by data contract. | L: allowed-model-deployment-skus; explicit SKU allowlist | D [CAF] [DeploymentTypes] |

## 2. Network Isolation

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-011 | P0 | Audit approved public IPs and restrictive defaults across Cognitive Services, Search, and ML. | Check every active IP/CIDR rule, not merely whether one exists. Disabled public access is also valid; VNet and trusted-service findings are separate. | L: restrict-ai-public-ip-access; B05 alone is insufficient; B02/B03 excluded private-only overlays | D [CognitiveNetwork] [SearchNetwork] [MLNetwork] |
| AI-GOV-104 | P0 | Audit configured Azure AI VNet rules against approved subnet IDs. | Check all configured rules, including dormant entries. A subnet allowlist is not VNet injection and does not prove the subnet or its service endpoint is operational. | L: restrict-ai-virtual-network-rules; Cognitive Services accounts only | D [CognitiveNetwork] |
| AI-GOV-105 | P0 | Audit enabled trusted-service bypass against explicit approval. | AzureServices can bypass IP rules; permission to use that exception must be reviewed separately. Default is no trusted-service bypass. | L: restrict-ai-trusted-services; `allowTrustedServices`; Cognitive Services/Search | D [CognitiveNetwork] [SearchNetwork] |
| AI-GOV-014 | P0 | Audit private-endpoint existence on Private Link-capable AI services and dependencies. | Require an Approved connection independently of approved public IPs; connection state does not prove DNS, routing, or disabled public access. | B04, B36, B38, B39, B40: core AI; B41: ACR; B42: Storage; B43: Key Vault; B44: HSM; B45: Cosmos DB; B46: PostgreSQL; B47: SQL; B48, B49: Redis; B50: Batch; B51: Web/Functions; B52: Synapse; B53: Data Factory; B54: Purview; B55: Monitor Private Link Scope; L: require-ai-private-endpoints, require-ai-monitor-private-link-scope | G [Tools] [Search] [ML] |
| AI-GOV-016 | P0 | Require approved-outbound-only managed networking for ML workspaces. | Restrict training, package, and inference egress instead of allowing arbitrary internet destinations. | B06: Audit; review every outbound exception | G [ML] |
| AI-GOV-103 | P0 | Audit customer VNet injection on supported AI resource types. | Check Foundry agent injection separately from Databricks workspace VNet parameters; Private Link and ML managed-network isolation do not prove either configuration exists. | L: require-foundry-vnet-injection for project-enabled AIServices accounts; B56: Databricks customer VNet parameters | D [FoundryNetworkInjection] |
| AI-GOV-017 | P0 | Require supported ML and AKS compute to use network isolation. | Reduce publicly reachable compute and control-plane paths; private API access does not prove private workload ingress. | B07: ML compute VNet; B57: AKS private cluster; Audit | G [ML] |
| AI-GOV-018 | P1 | Assess private DNS for AI private endpoints. | Detect name-resolution failures and unintended public routing. | C: audit zone links/settings; X: resolution tests; B08 excluded because it cannot audit | G [ML] |
| AI-GOV-019 | P0 | Limit AI data and key dependencies to approved IPs/networks or private access. | Securing the model endpoint leaves a gap if Storage, Key Vault, databases, or ACR remain unrestricted. | B41: Container Registry; see AI-GOV-014 for all included dependency endpoint checks; C: other service-specific selected-public-network controls | D [Baseline] |
| AI-GOV-020 | P0 | Prevent clients from bypassing the approved AI gateway. | Otherwise gateway token, safety, and access controls can be evaded by direct backend calls. | X: backend RBAC, private networking, and negative connectivity tests | D [CAF] [Gateway] |

## 3. Identity and Access

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-021 | P0 | Assess whether local/key authentication is disabled on supported AI accounts. | Identify shared-secret exposure and assess migration to attributable, scoped Entra authentication. | B01: Audit | G [Tools] |
| AI-GOV-022 | P0 | Assess whether local authentication is disabled on AI Search. | Identify shared admin/query keys where Entra-capable consumers are available. | B09: Audit | G [Search] |
| AI-GOV-023 | P0 | Assess whether local authentication is disabled on ML compute. | Identify credential sharing and local access paths. | B10: Audit; this is not an inference-endpoint auth policy | G [ML] |
| AI-GOV-024 | P0 | Require approved Entra authentication on ML online endpoints. | Prevent endpoint keys from bypassing identity and authorization controls. | C: online-endpoint auth-mode aliases and API validation | D [CAF] |
| AI-GOV-025 | P0 | Assess managed identity on Cognitive Services accounts. | Authenticate supported outbound service access without embedded credentials. Identity presence does not prove correct RBAC. | B11: Audit | G [Tools] |
| AI-GOV-026 | P1 | Assess user-assigned identity for ML where lifecycle portability is needed. | Preserve a reviewed identity across workspace replacement. System-assigned identity remains valid for other workloads. | B12: Audit; scope only to workloads needing this choice | G [ML] |
| AI-GOV-027 | P0 | Use workload identity for AI workloads on AKS. | Avoid long-lived service principal secrets in pods. | C: host configuration policies; X: federated identity, service accounts, and RBAC review | D [CAF] |
| AI-GOV-028 | P0 | Use secretless identity for Foundry connections and AI data access. | A managed-identity resource can still contain key-based tool or storage connections. | X: connection configuration checks and CI/CD secret scanning | D [CAF] [Agents] |
| AI-GOV-029 | P0 | Enforce least privilege and time-bound privileged access. | Separate model deployment, data access, safety administration, and operator duties. | X: Entra PIM, Conditional Access, RBAC, and access reviews | G [CAF] [Agents] |
| AI-GOV-030 | P0 | Require authenticated bot channels and AI application entry points. | Private backends do not prevent an unauthenticated application from becoming a public proxy. | C: supported host settings; X: Bot/channel, APIM, and application authorization tests | D [Agents] [Baseline] |

## 4. Data and Cryptography

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-031 | P1 | Assess customer-managed encryption keys for qualifying AI accounts. | Meet customer key-control obligations where needed and supported; platform-managed encryption is already provided otherwise. | B13: Audit; scope by compliance need and supported kind | G [Tools] |
| AI-GOV-032 | P1 | Assess customer-managed encryption for qualifying AI Search workloads. | Check actual index/object coverage, not just an enforcement flag. | B14: AuditIfNotExists; B15 excluded because it cannot audit | G [Search] |
| AI-GOV-033 | P1 | Assess customer-managed keys for qualifying ML workspaces. | Apply the key ownership requirement consistently to ML metadata and supported assets. | B16: Audit; validate dependent storage/database encryption separately | G [ML] |
| AI-GOV-034 | P1 | Assess customer-owned storage where AI services support and require it. | Put supported persisted data under customer-controlled storage governance. This is not universally supported by all AI kinds. | B17: Audit; verify service applicability | G [Tools] |
| AI-GOV-035 | P0 | Block anonymous access to AI training and grounding blobs. | Prevent accidental disclosure of documents, images, audio, or model artifacts. | C: Storage account/container public-access built-ins | D [CAF] [Baseline] |
| AI-GOV-036 | P0 | Disable shared-key access to AI storage where dependencies support Entra. | Reduce unscoped credentials and make access attributable; assess SAS and service compatibility. | C: Storage shared-key policy plus connection migration | D [CAF] |
| AI-GOV-037 | P0 | Require Key Vault soft delete and purge protection for AI keys. | Reduce irreversible loss of encryption keys and downstream AI data availability. | C: Key Vault recovery/protection built-ins | D [Baseline] |
| AI-GOV-038 | P1 | Enforce AI key/secret rotation and expiry policies. | Bound credential exposure and detect certificates or keys approaching expiration. | C: Key Vault data-plane policies where available; X: rotation automation and connection validation | D [CAF] |
| AI-GOV-039 | P0 | Preserve document- and tenant-level authorization in RAG retrieval. | A secure Search service can still return another user's documents if application filtering is wrong. | X: permission-aware indexing/retrieval and cross-user negative tests | G [CAF] [Agents] |
| AI-GOV-040 | P0 | Control sensitive data ingestion, retention, and deletion. | Cover prompts, completions, vectors, uploads, audio/images, training data, and derived copies, not just source files. | X: Purview/DLP, data contracts, service settings, and deletion evidence | G [CAF] [NIST] |

## 5. Models and Supply Chain

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-041 | P0 | Audit Foundry deployments against approved models. | Identify unreviewed models and router-selected models in production. Test asset-prefix matching carefully. | B18: Audit; leave publisher list empty for asset-only approval | G [Models] |
| AI-GOV-042 | P0 | Audit preview models in production unless exempted. | Identify reliance on changing terms, behavior, or availability. The built-in's `denyPreviewModels` toggle defines eligibility; an Audit effect still only reports findings. | B19: Audit; verify definition status and parameters | G [Models] [Tools] |
| AI-GOV-043 | P0 | Restrict model publishers or distribution sources when required. | Apply procurement, licensing, and processing commitments to third-party models. Publisher approval is broader than model approval. | B18 publisher allowlist; B19 Direct-from-Azure eligibility | G [Models] |
| AI-GOV-044 | P0 | Audit ML deployments against approved registry model assets. | Assess non-Cognitive-Services deployment paths as well as Foundry deployments. | B20: preview Audit; test applicable ML deployment surfaces | G [ML] |
| AI-GOV-045 | P0 | Assess ML deployment source registries. | Identify models supplied by an untrusted registry even when the model name appears familiar. | C: audit source registry with verified aliases; B21 excluded because it cannot audit | G [ML] |
| AI-GOV-046 | P1 | Pin production model versions to an approved release set. | Approval of a model family or an asset prefix does not necessarily approve every version. | C: exact model/version checks using verified aliases; X for data-plane releases | D [CAF] [Models] |
| AI-GOV-047 | P1 | Govern automatic model upgrade behavior. | Choose an explicit, supported upgrade policy and validate changes without blocking mandatory service retirements. | C: deployment upgrade-option aliases; X: canary/evaluation release gate | D [CAF] |
| AI-GOV-048 | P1 | Reject model releases failing provenance and supply-chain checks. | Detect unsafe serialization, tampering, untrusted packages, and missing artifact attestations. | X: signed artifacts, scanning, and controlled promotion pipelines | D [OWASP] |
| AI-GOV-049 | P0 | Approve licenses, training rights, and model usage terms. | Technical deployability does not establish the legal right to use a model or training corpus. | X: procurement, provenance records, and legal approval | G [CAF] [NIST] |
| AI-GOV-050 | P0 | Restrict fine-tuning to approved identities and datasets. | Prevent sensitive or unlicensed data from entering training jobs or model artifacts. | X: RBAC, dataset approval, job/pipeline controls, and retention checks | D [CAF] [OWASP] |

## 6. Responsible AI and Content Safety

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-051 | P0 | Audit model content-filter coverage as one safety baseline. | Check prompt/completion thresholds, required harmful-content categories, severity coverage, and control mode together. Configuration compliance is not proof of runtime safety. | B22, B23, B24, B25: preview Audit; X: runtime evaluation evidence | G [Tools] [RAI] |
| AI-GOV-055 | P0 | Audit the agent-specific content-safety baseline. | Check agent prompt filtering and harmful-content coverage separately from the underlying model's configuration. | B26, B27: preview Audit; verify agent surface support | G [Tools] |
| AI-GOV-057 | P0 | Enable and test direct prompt-attack defenses. | Detect jailbreak attempts without assuming filtering is a complete security boundary. | X: Prompt Shields/guardrail configuration and adversarial tests | G [RAI] [OWASP] |
| AI-GOV-058 | P0 | Defend against indirect prompt injection from retrieved content and tools. | Documents, websites, and tool output are untrusted inputs, not privileged instructions. | X: isolation, tool permission limits, guardrails, and adversarial RAG tests | G [Agents] [OWASP] |
| AI-GOV-059 | P1 | Apply protected-material detection where supported and required. | Reduce unauthorized reproduction risks; a detector is not proof of copyright compliance. | X: service filter configuration, evaluations, and legal review | G [CAF] [RAI] |
| AI-GOV-060 | P0 | Require documented safety and quality evaluation gates before release. | Measure groundedness, harmful output, fairness, privacy, and accessibility for the actual use case. | X: Foundry/ML evaluations, risk review, and CI/CD approval gates | G [RAI] [NIST] |

## 7. Agents and Tools

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-061 | P1 | Register every production agent with an owner, identity, and purpose. | Discover agent instances that do not appear as distinct ARM resources. | X: Entra Agent ID where supported plus service/application inventory | G [CAF] [Agents] |
| AI-GOV-062 | P0 | Allow only approved tools, MCP servers, and operations per agent. | Limit the actions an agent can actually take, not just which model it uses. | X: tool registry, connection approval, and runtime authorization | D [Agents] [OWASP] |
| AI-GOV-063 | P0 | Restrict agent tool egress destinations. | Prevent data exfiltration through arbitrary URLs, webhooks, or external model endpoints. | C: network controls; X: gateway/runtime destination allowlists | D [Agents] [OWASP] |
| AI-GOV-064 | P0 | Give each agent/tool only the permissions its task requires. | Avoid shared high-privilege identities and confused-deputy access. | X: scoped identities, delegated-user authorization, and tool-level permission tests | G [Agents] |
| AI-GOV-065 | P0 | Require human approval for high-impact agent actions. | Gate financial, destructive, privileged, or external communication actions outside model reasoning. | X: deterministic approval workflow with independent authorization | D [Agents] [NIST] |
| AI-GOV-066 | P0 | Sandbox code execution and interpreter tools. | Prevent generated code from accessing host credentials, unrestricted networks, or neighboring tenants. | C: host isolation policies; X: execution sandbox and runtime limits | D [OWASP] |
| AI-GOV-067 | P0 | Isolate agent memory, sessions, and vector stores by tenant/user. | Prevent cross-tenant retrieval, shared-memory leakage, and unauthorized session reuse. | X: data partitioning, access checks, and cross-session negative tests | D [Agents] |
| AI-GOV-068 | P1 | Expire agent threads, files, and memory according to retention rules. | Avoid indefinite sensitive-data persistence in secondary copies. | X: supported service APIs, lifecycle jobs, legal holds, and deletion verification | D [CAF] [NIST] |
| AI-GOV-069 | P0 | Disable unapproved browser, computer-use, shell, and write capabilities. | Keep an agent from acquiring unnecessary high-impact capabilities through tools. | X: explicit capability allowlists and runtime checks | D [Agents] [OWASP] |
| AI-GOV-070 | P1 | Bound agent steps, recursion, concurrency, and execution time. | Limit runaway loops, resource exhaustion, and unbounded autonomous activity. | X: orchestrator limits, cancellation, and circuit breakers | D [OWASP] |

## 8. Observability and Compliance Evidence

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-071 | P0 | Audit AI diagnostic coverage and approved log destinations. | Check Cognitive Services, ML workspaces, and Search under one evidence objective. A setting pointing to an unmonitored destination is insufficient; resource logs do not automatically include agent traces. | B28, B29, B30: AuditIfNotExists; B31: AuditIfNotExists for Cognitive Services destination; C: other destination checks | G [Tools] [ML] [Search] [CAF] |
| AI-GOV-075 | P1 | Configure AI availability, throttling, latency, and token-usage alerts. | Detect service degradation and consumption anomalies before they become incidents. | C: Monitor alert resource checks; X: baseline tuning and response tests | G [CAF] |
| AI-GOV-076 | P1 | Correlate agent, model, retrieval, and tool execution traces. | Reconstruct why an agent acted and which identities or data sources it used. | X: application tracing with access controls and a supported telemetry sink | G [RAI] [Agents] |
| AI-GOV-077 | P0 | Redact secrets and sensitive content from AI telemetry. | Logging raw prompts or tool arguments can create a second, less protected data store. | X: instrumentation controls, redaction tests, sampling, and log access review | D [CAF] [NIST] |
| AI-GOV-078 | P1 | Enable applicable Defender AI discovery and threat protection. | Detect risky AI assets and runtime threats; verify plan, region, and service support. | C: Defender plan policies; X: alert routing and investigation procedures | G [CAF] |
| AI-GOV-079 | P1 | Protect audit evidence with approved retention and tamper resistance. | Preserve useful incident evidence without retaining unnecessary sensitive content. | C: storage/log settings; X: retention and evidence-access governance | D [CAF] [NIST] |
| AI-GOV-080 | P1 | Time-bound and review AI policy exemptions. | Prevent emergency exceptions from silently becoming permanent governance gaps. | X: exemption owner, justification, `expiresOn`, review workflow, and expiry alerts | D [ALZ] [NIST] |

## 9. Compute and Hosting

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-081 | P0 | Prohibit unapproved public IP exposure on AI compute. | Protect GPU VMs, ML compute, and supporting hosts from direct internet access. | C: platform-specific public-IP/network policies; verify managed-service exceptions | D [Baseline] |
| AI-GOV-082 | P1 | Restrict AI compute to approved VM/GPU SKUs. | Control hardware cost, regional support, security features, and operational complexity. | C: VM, VMSS, ML compute, AKS, and Databricks-specific SKU controls | D [CAF] |
| AI-GOV-083 | P0 | Enforce restricted pod security for AI on Kubernetes. | Prevent privileged containers, host access, and unsafe capabilities. | C: Azure Policy for Kubernetes/Gatekeeper constraints; test necessary GPU-driver exceptions | D [OWASP] [Baseline] |
| AI-GOV-084 | P0 | Restrict AKS API access to approved IP ranges or a private control plane. | Protect self-hosted model and agent administration without requiring every approved public API endpoint to be disabled. | C: AKS authorized IP range and private-cluster policies | D [Baseline] |
| AI-GOV-085 | P0 | Deploy AI containers only from approved registries and vetted artifacts. | Reduce compromised image and dependency supply-chain risk. | C: Kubernetes/host image constraints; X: digest pinning, scanning, and signatures | D [OWASP] |
| AI-GOV-086 | P1 | Assess whether ML compute instances use supported, updated software. | Flag outdated managed images; maintenance requires an independent operational workflow. | B32: Audit via the `effects` parameter | G [ML] |
| AI-GOV-087 | P0 | Assess AI Search tier support for selected-IP firewalls or Private Link. | The Free tier cannot provide the selected-IP firewall baseline; use Basic or higher and verify the chosen network features. | B33: Audit for Private Link-capable tiers; verify firewall support separately | D [Search] [SearchNetwork] |
| AI-GOV-088 | P1 | Assess supported zone-redundant Search configurations. | Identify zone-failure exposure; validate region and replica requirements. | B34: preview Audit | G [Search] |
| AI-GOV-089 | P1 | Set minimum production inference replicas and bounded autoscale. | Avoid single-instance failure and uncontrolled scale-out where the hosting service exposes these settings. | C: ML/AKS/Container Apps host-specific replica and scaling controls | D [CAF] |
| AI-GOV-090 | P1 | Require inference health probes and release rollback readiness. | A deployed endpoint is not necessarily ready, responsive, or recoverable. | C: exposed host settings; X: readiness, load, failure, and rollback tests | D [CAF] [Baseline] |

## 10. FinOps, Resilience, and Lifecycle

| ID | Priority | Proposed policy / scope | Why it matters | Implementation | Basis |
| --- | --- | --- | --- | --- | --- |
| AI-GOV-091 | P1 | Assess idle shutdown on ML compute instances. | Identify avoidable idle compute cost while honoring approved operational exceptions. | B35: Audit | G [ML] [CAF] |
| AI-GOV-092 | P2 | Minimize idle nonproduction training and inference capacity. | Use supported scale-to-zero or schedules; do not assume every AI deployment can be paused without cost. | C: host-specific scale settings; X: scheduling and service-specific cost checks | G [CAF] |
| AI-GOV-093 | P1 | Cap model deployment capacity and allocate quota deliberately. | Limit accidental capacity growth; a per-resource limit is not an aggregate token or spending budget. | C: verified capacity/SKU aliases; X: quota allocation and aggregate monitoring | G [CAF] |
| AI-GOV-094 | P0 | Enforce per-consumer token, request, and concurrency limits. | Bound abuse and noisy-neighbor effects at runtime. API Management policies are not Azure Policy definitions. | X: APIM AI gateway quotas/rate limits and backend bypass prevention | G [CAF] [Gateway] |
| AI-GOV-095 | P1 | Configure budgets, anomaly detection, and cost-owner notifications. | Give operators early warning of unusual spend; Azure budgets are not a hard real-time spending stop. | X: Cost Management budgets, alerts, and a reviewed response workflow | G [CAF] |
| AI-GOV-096 | P0 | Constrain fallback routing to approved models, regions, and providers. | Outage failover must not bypass normal residency, safety, or procurement constraints. | X: gateway/router configuration and tested failover; reuse 001, 010, and 041-043 | D [CAF] [Models] |
| AI-GOV-097 | P1 | Test AI recovery against agreed RTO and RPO. | Recover indexes, data, keys, model configuration, and dependencies as one workload. | C: available backup settings; X: restore and regional failover exercises | G [CAF] |
| AI-GOV-098 | P1 | Track model, API, SDK, and service retirement dates. | Prevent supported production deployments from becoming unavailable or insecure without an owner action. | X: inventory/retirement feed, alerts, evaluation, and controlled model-allowlist updates | G [CAF] |
| AI-GOV-099 | P2 | Decommission expired AI environments and revoke their access. | Remove orphaned endpoints, identities, tool credentials, and retained data under approved retention rules. | X: owner-reviewed lifecycle automation with recovery and legal-hold checks | D [CAF] [NIST] |
| AI-GOV-100 | P1 | Manage AI governance definitions and assignments as reviewed code. | Make guardrail changes testable, versioned, traceable, and reversible across environments. | X: CI/CD, sandbox deployment tests, approval gates, and drift detection | D [ALZ] [NIST] |

## Important Deductions

1. **Resource residency, model processing residency, and data replication are separate controls.** Apply 001, 009, 010, and 096 together where required. A region tag or account location is not a residency guarantee.
2. **Publisher and model approvals can broaden each other.** B18 considers a model compliant through an allowed publisher **or** an allowed asset ID. For a strict asset-only assessment, do not also approve its entire publisher. Review prefix behavior and model-router members, including new versions.
3. **Selected networks are not authorization and do not prove gateway enforcement.** Check every configured source, bypass setting, DNS, private endpoint approval where used, backend RBAC, and direct-call behavior independently. Public access need not be disabled when the actual service firewall restricts it to approved sources. This audit pack only assesses that configuration.
4. **Audit-only policies do not prevent deployment or runtime abuse.** Findings identify gaps for review. Evaluate the actual service guardrails and authorization separately; this pack does not install or remediate them.
5. **Tags are assertions, not proof.** The seven AI tags support inventory and assessment routing but do not prove authorization, human approval, legal compliance, or actual model behavior.
6. **A resource property is not automatically an Azure Policy alias.** Inspect provider aliases and test actual API versions before implementing C items. Use `All` for applicable child-resource controls and array counts for collection constraints; do not assume tags or location exist on children.
7. **Documentation can disagree with the deployed definition.** The model deployment guide describes eligibility as GA, while the policy index lists B19 as preview. This catalogue conservatively preserves the index status. Inspect the definition in the target cloud before rollout; names, versions, effects, and availability can change.

## Audit Rollout

1. Map resource types, account kinds, deployment surfaces, data flows, owners, and existing ALZ assignments. Avoid assigning duplicate or contradictory controls.
2. Decide explicit allowed locations, kinds, deployment SKUs, public IP/CIDR rules, subnet IDs, tag names/values, and exceptions. Required allowlists intentionally have no defaults; an empty allowlist matches nothing and is not an exemption. Do not combine public-disable overlays with scopes intended to allow approved public sources.
3. Register only the applicable custom definitions and audit-capable built-ins. Group assessments by ownership and workload needs, not by a target number of controls.
4. Set every selected definition to its supported `Audit` or `AuditIfNotExists` effect. Exclude non-auditing built-ins instead of assigning Deny, Modify, DeployIfNotExists, or Disabled. Do not use effect overrides to introduce enforcement.
5. Test compliant, noncompliant, omitted-property, update, and exemption scenarios in a nonproduction scope. Verify findings and that the policy does not block requests or change resources. Confirm relevant account kinds, child resources, and API versions; allow for compliance/assignment propagation delays.
6. Validate findings against actual firewall rules, client connectivity, identities, and logging destinations. Observe ML's post-creation IP-rule sequencing and isolation prerequisites. Changes to service configuration are a separate, owner-approved process.
7. Do not configure remediation tasks or remediation identities for this audit-only pack. Audit findings do not repair existing resources, inherit tags, or deploy missing dependencies.
8. Prioritize actionable P0 findings, record time-bound exemptions, and retire duplicate or low-value checks. Keep the selected policies in audit mode; changes to that contract require a separate decision.

Run the offline checks in PowerShell 7 from the repository root; no Az modules or Azure sign-in are required:

```powershell
& ./policy/aigovernance/Test-AiGovernance.ps1
```

Offline checks cover JSON structure, unique catalogue IDs, manifest links, parameter references, audit-only effects, the AI tag vocabulary, initiative generation, root scope, and representative custom-rule cases, including mixed IP/subnet arrays, bypasses, and empty lists. They do not impose a catalogue size or require gap-free numbering. Fixtures use synthetic addresses and alias-keyed inputs with object-shaped rule arrays, not deployment parameters. **They are not an Azure Policy engine or proof of live service compatibility.** The deployment script additionally checks live aliases, validates `count.field` array roots, reads built-in schemas, and verifies published definitions. Before assigning in another environment, review its live definitions and run the read-only preflight.

## Sources

These sources inform the recommendations; D rows are deductions, not assertions that a source mandates the exact policy. NIST and OWASP are conceptual risk references, not Azure Policy catalogs. Legal and industry-specific compliance mappings require a separate assessment.

- [CAF: Govern Azure platform services for AI][CAF]
- [ALZ: Ready your AI environment and apply landing-zone governance][ALZ]
- [Baseline: Foundry in an Azure landing zone][Baseline]
- [Foundry Tools built-in policy reference][Tools]
- [AI Search built-in policy reference][Search]
- [Azure Machine Learning built-in policy reference][ML]
- [Foundry model deployment policies][Models]
- [Foundry deployment types and the documented SKU policy alias][DeploymentTypes]
- [Azure Policy parameterized tag examples][ParameterPattern]
- [Cognitive Services selected-network access][CognitiveNetwork]
- [AI Search selected-IP firewall and trusted-service exceptions][SearchNetwork]
- [ML workspace selected-IP access and restrictions][MLNetwork]
- [Community Azure Policy alias index, to cross-check against the target cloud][Aliases]
- [Responsible AI for Microsoft Foundry][RAI]
- [Govern and secure AI agents][Agents]
- [API Management AI gateway capabilities][Gateway]
- [NIST AI Risk Management Framework][NIST]
- [OWASP Top 10 for LLM Applications][OWASP]
- [Azure Policy definition structure and aliases][Policy]
- [Create and manage policy and initiative definitions][PolicyDeployment]
- [Azure Policy initiative parameter and reference structure][Initiative]

[CAF]: https://learn.microsoft.com/azure/cloud-adoption-framework/ai/platform/governance
[ALZ]: https://learn.microsoft.com/azure/cloud-adoption-framework/ai/ready
[Baseline]: https://learn.microsoft.com/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-landing-zone
[Tools]: https://learn.microsoft.com/azure/ai-services/policy-reference
[Search]: https://learn.microsoft.com/azure/search/policy-reference
[ML]: https://learn.microsoft.com/azure/machine-learning/policy-reference?view=azureml-api-2
[Models]: https://learn.microsoft.com/azure/foundry/how-to/model-deployment-policy
[DeploymentTypes]: https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types#restrict-deployment-types-with-azure-policy
[ParameterPattern]: https://learn.microsoft.com/azure/governance/policy/samples/pattern-parameters#sample-1-string-parameters
[CognitiveNetwork]: https://learn.microsoft.com/azure/ai-services/cognitive-services-virtual-networks
[SearchNetwork]: https://learn.microsoft.com/azure/search/service-configure-firewall
[MLNetwork]: https://learn.microsoft.com/azure/machine-learning/how-to-configure-private-link?view=azureml-api-2#enable-public-access-only-from-internet-ip-ranges
[Aliases]: https://policyalias.mats.codes/
[RAI]: https://learn.microsoft.com/azure/foundry/responsible-use-of-ai-overview
[Agents]: https://learn.microsoft.com/azure/cloud-adoption-framework/ai-agents/governance-security-across-organization
[Gateway]: https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities
[NIST]: https://www.nist.gov/itl/ai-risk-management-framework
[OWASP]: https://genai.owasp.org/llm-top-10/
[Policy]: https://learn.microsoft.com/azure/governance/policy/concepts/definition-structure-basics
[PolicyDeployment]: https://learn.microsoft.com/azure/governance/policy/tutorials/create-and-manage
[Initiative]: https://learn.microsoft.com/azure/governance/policy/concepts/initiative-definition-structure
[FoundryNetworkInjection]: https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts#networkinjection
[MLCompute]: https://learn.microsoft.com/azure/templates/microsoft.machinelearningservices/workspaces/computes
[HealthBotNetwork]: https://learn.microsoft.com/security/benchmark/azure/baselines/microsoft-health-agent-healthbot-security-baseline#network-security