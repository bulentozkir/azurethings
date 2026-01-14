# Azure Service Retirement Alert – Deploy to Azure

This repository contains an **Azure Resource Manager (ARM) template** that deploys an **Azure Monitor Scheduled Query Rule** to detect **Azure Service Retirements** and notify teams before retirement dates are reached.

---

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
The name of the Azure Monitor **Scheduled Query Rule**.

**Default value**  
alert-azureserviceretirements-01

---

### actiongroups_externalid

**Description**  
An **array of Azure Resource IDs** referencing **existing Azure Monitor Action Groups**. All Action Groups listed in the array will be triggered when the alert fires.

**Example single value**  
"/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/microsoft.insights/actiongroups/actiongroup1"

**Example multiple values**  
"/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/microsoft.insights/actiongroups/actiongroup1",
"/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/microsoft.insights/actiongroups/actiongroup2"

**Notes**  
- Action Groups must already exist  
- The deploying user must have read access to each Action Group
