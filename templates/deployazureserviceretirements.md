# Azure Service Retirement Alert – Deploy to Azure

This repository contains an **Azure Resource Manager (ARM) template** that deploys an **Azure Monitor Scheduled Query Rule** to detect **Azure Service Retirements** and notify teams before retirement dates are reached.

---

**Notes**

- ***The default template scope is per subscription; therefore, this template must be deployed separately for each subscription you want to receive notifications for resource retirements.***
- ***Action Groups must already exist.***
- ***The deploying user must have the **Monitoring Contributor** role at the subscription scope.***
- Assign the Log Analytics Reader to the system-assigned managed identity so that it has permissions fire alerts that send email notifications.
1.	Select Monitoring > Alerts in the Log Analytics workspace. Select OK if you're prompted that Your unsaved edits will be discarded.
2.	Select Alert rules.
3.	Select demo-arg-alert-rule.
4.	Select Settings > Identity > System assigned:
o	Status: On
o	Object ID: Shows the GUID for your Enterprise Application (service principal) in Microsoft Entra ID.
o	Permission: Select Azure role assignments:
o	Verify your subscription is selected.
o	Select Add role assignment:
o	Scope: Subscription
o	Subscription: Select your Azure subscription name.
o	Role: Log Analytics Reader
5.	Select Save.



## 🚀 Deploy to Azure

Click the button below to deploy this template using **Azure → Deploy a Custom Template**.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Ftemplates%2Fazsvcret.json)

---

## 🔧 Deployment Parameters

The Azure portal will prompt for the following **five parameters only** during deployment.

---

### Subscription

**Description**  
The Azure subscription where the Scheduled Query Rule will be created and where Azure Resource Graph queries will run.

---

### Resource Group

**Description**  
The resource group that will contain the Azure Monitor **Scheduled Query Rule (Log Alert)**.

---

### Region

**Description**  
The Azure region where the alert rule resource is deployed.  
The alert evaluates data at the **subscription scope** and is not limited by region.

---

### scheduledqueryrules_alert_name

**Description**  
The prefix of the Azure Monitor **Scheduled Query Rule** name. The subscription name and subscription id will be added to that alert rule name as suffix automatically.

---

### actiongroups_externalid

**Description**  
Action Group Azure Resource ID referencing an **existing Azure Monitor Action Group**. The Action Group will be triggered when the alert fires, meaning they will receive the alert as an email, thus it will be more convenient to use a distribution list as the recepient rather than an individual email.

**Example single value**  
/subscriptions/xxxxx-yyyyy-zzzz/resourceGroups/<rg-name>/providers/microsoft.insights/actiongroups/actiongroup1



