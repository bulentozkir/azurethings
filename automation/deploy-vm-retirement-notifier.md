# VM retirement notifier

Deploys an Azure Logic App that emails a table of VMs and VM scale sets whose size is already retired or retires within the next 6 months, using live lookups from Microsoft Learn and the Azure Compute SKUs REST API instead of hardcoded SKU catalogs.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Fautomation%2Fdeploy-vm-retirement-notifier.json)

Template: [deploy-vm-retirement-notifier.json](deploy-vm-retirement-notifier.json)

## What gets deployed

| Resource | Purpose |
|---|---|
| Logic App (Consumption) with a system-assigned managed identity | Runs the check every other Monday |
| Office 365 Outlook API connection | Sends the email |
| Reader role assignment (optional) | Lets the Logic App read VMs and Compute SKUs in the deployment subscription |

No Storage account, Function App, or App Service plan is created.

## How it works

- Runs every other Monday at 09:00 (Turkey Standard Time), starting 12 October 2026. You can change this in the **Recurrence** trigger.
- Fetches Microsoft's live [VM size retirements markdown page](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions?accept=text/markdown) on every run (`Fetch_retirement_catalog`) and parses the published retiring series names, retirement dates, and modernization guide links natively in Logic Apps. If the page table structure changes and cannot be parsed, the run fails with `RetirementCatalogFormatChanged` rather than silently skipping alerts.
- Queries Azure Resource Graph (`Find_risky_VMs`) across `subscriptionIds` and dynamically matches deployed VM and VM scale set sizes against the parsed Microsoft Learn catalog without hardcoded SKU series lists or dates. Dedicated Host entries are excluded.
- When at least one VM or scale set is at risk, calls the [Azure Compute Resource SKUs REST API](https://learn.microsoft.com/en-us/rest/api/compute/resource-skus/list) (`Get_compute_skus`) per affected subscription and region to look up live `vCPUs` and `Memory (GiB)` specifications (`n/a` if an older retired SKU is no longer listed in the catalog).
- Sends one email when at least one VM or scale set is retired or retires within `retirementHorizonMonths`. No email is sent when nothing is at risk.
- Email columns: status, retirement date, subscription ID, subscription name, resource group, resource name, type, SKU, vCPUs, memory (GiB), published series, clickable migration guide link, and region.
- Resource Graph silently skips subscriptions it can't read. If the Logic App identity can't read a listed subscription, the run fails with `MissingReaderAccess`.
- The email lists up to 1,000 resources.
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
| Location | Resource group region | Region for the Logic App and the connection |
| Workflow State | `Disabled` | Keep disabled until the connection is authorized |
| Assign Reader Role | `true` | Grants the Logic App identity Reader on the deployment subscription. Requires Owner or User Access Administrator. |

## After deployment

1. **Authorize email.** Open the Office 365 connection > **Edit API connection** > **Authorize** > **Save**. Email is sent from the account you sign in with.
2. **Grant access to other subscriptions.** Give the Logic App identity **Reader** on every other subscription in `subscriptionIds`. The principal ID is in the deployment output `workflowPrincipalId`.

   ```bash
   az role assignment create --assignee-object-id <workflowPrincipalId> --assignee-principal-type ServicePrincipal --role Reader --scope /subscriptions/<subscriptionId>
   ```

3. **Enable the Logic App.** To test right away, select **Run trigger**.

To change recipients, subscriptions or the horizon later, open the Logic App designer > **Parameters**.

## Notes and limitations

- Retirement dates and migration links come directly from [VM size retirements and capacity growth restrictions](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) at runtime. Coverage reflects the VM retirement tables currently published on that page; check the linked guide on any finding for regional extension dates, OS/NVMe/Gen2 requirements, and quota availability before resizing.
