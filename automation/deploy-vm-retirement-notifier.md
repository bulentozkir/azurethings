# VM retirement notifier

Deploys an Azure Logic App and a small Azure Function that email VMs and VM scale sets matching Microsoft's live retirement documentation. Includes already-retired sizes and retirements within the next 6 months. No Azure Advisor dependency or embedded SKU/date/replacement catalog.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Fautomation%2Fdeploy-vm-retirement-notifier.json)

Template: [deploy-vm-retirement-notifier.json](deploy-vm-retirement-notifier.json)

## What gets deployed

| Resource | Purpose |
|---|---|
| Logic App (Consumption) with a system-assigned managed identity | Runs the check every other Monday |
| Office 365 Outlook API connection | Sends the email |
| Azure Function (Windows Consumption, Node.js 24) with a system-assigned managed identity | Reads live Microsoft Learn pages, inventory and Compute SKU metadata |
| Consumption hosting plan and Storage account with public blob access disabled | Hosts the Function code and runtime state |
| Reader role assignment (optional) | Lets the Function read the deployment subscription |

The Function and Storage account add consumption/storage charges. Choose a region that supports both Logic Apps Consumption and Azure Functions Windows Consumption. This template targets Azure public cloud.

## How it works

- Runs every other Monday at 09:00 (Turkey Standard Time), starting 12 October 2026. You can change this in the **Recurrence** trigger.
- Fetches Microsoft's [retirement tables](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) using Microsoft Learn's `?accept=text/markdown` representation on every run. No local or stale fallback catalog is used.
- Derives matching rules from the published series labels and exact sizes, rather than maintaining a list of retiring SKUs. Dedicated Host entries are excluded.
- Reads VMs and scale sets through the Resource Graph REST API, following continuation tokens. Every subscription is checked explicitly first, because Resource Graph silently skips subscriptions it can't read.
- Resources with no scalar SKU produce an explicit warning. For flexible scale sets without a model-level size, their individual VMs are assessed separately.
- Reads the linked retirement/modernization pages. Regional extensions expressed with English dates and recognized Azure region names are resolved using the live Azure Locations API. Unresolved regional exceptions are shown as **Review regional scope**, with the source link, not asserted as confirmed retirements.
- Looks up the affected source sizes through the [Compute Resource SKUs API](https://learn.microsoft.com/rest/api/compute/resource-skus/list), including pagination, for actual available-vCPU and memory specifications. Missing retired SKUs are reported as **Unavailable** with a warning; names and specifications are never invented.
- Sends one email when there are findings or lookup warnings. No email is sent when there are neither. A failed source/API request fails the run instead of returning a clean bill of health.
- Email columns include status, retirement date, subscription ID/name, resource group/name, type, SKU, vCPUs, memory, region, published series, migration guidance URL and scope note.
- The previous calculated **Recommended SKU** column is replaced with official **Migration guidance** links. CPU/memory equivalence alone does not establish a safe replacement; the notifier makes no compatibility, quota or capacity guarantee.
- Scans the full paginated inventory; the email lists the first 1,000 findings and states the full finding count.
- Read-only: it never changes your VMs.

## Deploy

1. Select **Deploy to Azure** above.
2. Choose the subscription and resource group.
3. Enter **Recipients** and **Subscription Ids** as JSON arrays, for example `["ops@contoso.com"]`.
4. Select **Review + create**.

### Deployment parameters

| Parameter | Default | Description |
|---|---|---|
| Recipients | None (required) | Email addresses, as a JSON array |
| Subscription Ids | Deployment subscription | Subscriptions to check, as a JSON array |
| Retirement Horizon Months | `6` | Include sizes that retire within this many months (1-60) |
| Workflow Name | `vm-retirement-notifier` | Logic App name |
| Office365 Connection Name | `office365-vm-retirement-notifier` | Outlook connection name |
| Location | Resource group region | Region for the workflow, Function, hosting plan, Storage and connection |
| Workflow State | `Disabled` | Keep disabled until the connection is authorized |
| Assign Reader Role | `true` | Grants the Function identity Reader on the deployment subscription. Requires Owner or User Access Administrator. |

## After deployment

1. **Authorize email.** Open the Office 365 connection > **Edit API connection** > **Authorize** > **Save**. Email is sent from the account you sign in with.
2. **Grant inventory access.** Give the Function identity **Reader** on every other subscription in `subscriptionIds`. If `assignReaderRole=false`, also grant access on the deployment subscription. Use deployment output **`lookupPrincipalId`**, not `workflowPrincipalId`.

   ```bash
   az role assignment create --assignee-object-id <lookupPrincipalId> --assignee-principal-type ServicePrincipal --role Reader --scope /subscriptions/<subscriptionId>
   ```

3. **Enable the Logic App.** To test right away, select **Run trigger**.

To change recipients, subscriptions or the horizon later, open the Logic App designer > **Parameters**.

### Upgrading an existing deployment

Redeploy this template, configure Reader access for the **new Function identity** on all subscriptions, then re-enable the Logic App. The existing Office 365 connection and recurrence are retained. The legacy `workflowPrincipalId` output still identifies the scheduler but is no longer the inventory reader. Old Reader grants on the Logic App identity are not removed automatically.

The Function endpoint requires a key, which the template wires into the lookup action with secure inputs/outputs. The key is not a deployment output. API/source failures appear as failed `Lookup_retirements` actions; inspect the Function logs for the error. No email is sent from a failed lookup.

## Coverage and limitations

- The Microsoft Learn retirement tables are the retirement source, **not an API with a stable retirement schema**. They may change format. Unrecognized labels, invalid dates, missing required table fields and unavailable linked pages fail the lookup explicitly.
- Coverage is limited to entries currently present in those tables. Older retirements removed from the index, retirements not yet documented there, and workload-specific exceptions may be absent. No email is not proof that every deployed size is supported.
- Regional prose is not a structured contract. Recognized extensions are applied automatically; ambiguous detected regional conditions require reviewing the linked source. Review Microsoft communications for customer-specific extensions.
- The Compute SKU API supplies current specifications and restrictions, **not retirement dates or successor mappings**. The report does not automatically select a replacement SKU.
- The HTTP lookup has a 95-second request budget to fit the Consumption workflow's synchronous HTTP limit. Large subscription/region scopes or slow sources can fail explicitly; split them across deployments if needed.

## Maintaining the parser

`retirement-lookup.js` is the readable, dependency-free Function source. It uses the supported file-based Node.js programming model so the ARM deployment can embed the entire Function without npm installation or an external package host. The template is self-contained.

After changing the source, regenerate the embedded copy with PowerShell 7:

```powershell
.\Sync-FunctionSource.ps1
```

Run the built-in Node.js tests:

```powershell
node --test .\retirement-lookup.test.js
```

To include live Microsoft Learn page/guide and regional-extension checks:

```powershell
$env:LIVE_LEARN = '1'
node --test .\retirement-lookup.test.js
```

Publish the updated JSON at the repository URL used by **Deploy to Azure** before using that button for the new version. Updating these local files does not update an existing Azure deployment.
