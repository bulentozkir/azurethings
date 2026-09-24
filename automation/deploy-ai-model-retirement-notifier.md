# AI model retirement notifier

Deploys an Azure Logic App that checks your Azure AI Foundry and Azure OpenAI model deployments every week. It emails a report when a deployed model is retiring soon or has already retired.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Fautomation%2Fdeploy-ai-model-retirement-notifier.json)

Template: [deploy-ai-model-retirement-notifier.json](deploy-ai-model-retirement-notifier.json)

## What gets deployed

| Resource | Purpose |
|---|---|
| Logic App (Consumption) with a system-assigned managed identity | Runs the weekly check |
| Office 365 Outlook API connection | Sends the email report |
| Reader role assignment (optional) | Lets the Logic App read AI resources in the subscription |

## How it works

- Runs weekly on Monday at 09:00 (Turkey Standard Time). You can change this in the **Recurrence** trigger.
- Lists the AI deployments in the configured subscriptions and looks up each model's retirement date in the account's model catalog.
- A deployment needs attention if **either** condition is true:
  - Its model retirement date is today or within the next `retirementHorizonMonths` calendar months.
  - Its model retirement date is before today.
- Sends one email per run, only when at least one deployment needs attention. Deployments with an unknown retirement date are listed, but don't trigger an email by themselves.
- Read-only: it never changes your model deployments.

## Deploy

1. Select **Deploy to Azure** above. The Azure portal opens **Custom deployment** with the template already loaded.
2. Choose the subscription and resource group.
3. Review the parameters, then select **Review + create** > **Create**.

> **Note:** The button deploys the template from the `main` branch of [bulentozkir/azurethings](https://github.com/bulentozkir/azurethings). The portal downloads it anonymously, so the repository must be public.

### Use in another repository

The button needs the template's full public URL; a relative link doesn't work. If you copy these files to another repository:

1. Open the template on GitHub, select **Raw**, and copy the URL.
2. URL-encode it:

   ```powershell
   [uri]::EscapeDataString("https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>/deploy-ai-model-retirement-notifier.json")
   ```

3. Replace the button link with `https://portal.azure.com/#create/Microsoft.Template/uri/<encoded-url>`.

For a private repository, deploy manually: in the Azure portal, open **Deploy a custom template** > **Build your own template in the editor** > **Load file**, select the template, then select **Save**.

### Deployment parameters

| Parameter | Default | Description |
|---|---|---|
| Workflow Name | `ai-model-age-notifier-95b0` | Logic App name |
| Office365 Connection Name | `office365-ai-model-age-notifier-95b0` | Outlook connection name |
| Location | Resource group region | Region for both resources |
| Workflow State | `Disabled` | Keep disabled until setup is complete |
| Assign Reader Role | `true` | Grants the Logic App identity Reader on this subscription. Requires Owner or User Access Administrator; set to `false` to assign it yourself. |

## After deployment

1. **Authorize email.** Open the Office 365 connection > **Edit API connection** > **Authorize** > **Save**. Reports are sent from the account you sign in with.
2. **Set the workflow parameters.** In the Logic App designer, open **Parameters**, update the values, then save or publish.

   | Workflow parameter | Default | Meaning |
   |---|---|---|
   | `subscriptionId` | Deployment subscription | Array of subscription IDs to check |
   | `recipientEmail` | Placeholder address | Report recipient; replace it |
   | `retirementHorizonMonths` | `12` | How many calendar months ahead to check |
   | `sendNotifications` | `true` | Set to `false` to run without sending email |
   | `maxPages` | `100` | Paging limit for each list request |

3. **Grant access to other subscriptions.** If `subscriptionId` includes other subscriptions, give the Logic App identity **Reader** on each one. The principal ID is in the deployment outputs as `workflowPrincipalId`.

   ```bash
   az role assignment create --assignee-object-id <workflowPrincipalId> --assignee-principal-type ServicePrincipal --role Reader --scope /subscriptions/<subscriptionId>
   ```

4. **Enable the Logic App.** The first run may start immediately; later runs follow the weekly schedule.
