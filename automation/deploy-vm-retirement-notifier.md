# VM retirement notifier

Deploys an Azure Logic App that emails a table of VMs and VM scale sets whose size is already retired or retires within the next 6 months, with a recommended replacement size.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Fautomation%2Fdeploy-vm-retirement-notifier.json)

Template: [deploy-vm-retirement-notifier.json](deploy-vm-retirement-notifier.json)

## What gets deployed

| Resource | Purpose |
|---|---|
| Logic App (Consumption) with a system-assigned managed identity | Runs the check every other Monday |
| Office 365 Outlook API connection | Sends the email |
| Reader role assignment (optional) | Lets the Logic App read VMs in the deployment subscription |

## How it works

- Runs every other Monday at 09:00 (Turkey Standard Time), starting 12 October 2026. You can change this in the **Recurrence** trigger.
- Queries Azure Resource Graph for the VMs and scale sets in `subscriptionIds` and matches each size to Microsoft's published retirement dates.
- Sends one email when at least one VM or scale set is retired or retires within `retirementHorizonMonths`. No email is sent when nothing is at risk.
- Email columns: status, retirement date, subscription ID, subscription name, resource group, resource name, type, SKU, recommended SKU and region.
- Recommended SKUs keep the vCPU and memory class, and the local temporary disk where possible, for example `Standard_D4s_v3` to `Standard_D4ds_v5`. GPU, HPC, confidential and M-series sizes show the replacement series.
- Resource Graph silently skips subscriptions it can't read. If the identity can't read a listed subscription, the run fails with `MissingReaderAccess`.
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
| Location | Resource group region | Region for both resources |
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

## Retirement data

Retirement dates and recommended sizes are in the **Risk_query** action. Update it when Microsoft announces new retirements. Source: [VM size retirements and capacity growth restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions).
