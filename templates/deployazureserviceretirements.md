# Azure Service Retirement Alert – ARM Template Deployment

This repository provides an **Azure Resource Manager (ARM) template** that deploys an **Azure Monitor Scheduled Query Rule** to detect **Azure Service Retirements** and notify stakeholders before retirement dates are reached.

---

## 🚀 Deploy to Azure

Click the button below to deploy this template using the **Azure – Deploy a Custom Template** wizard.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](
https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Ftemplates%2Fazsvcret.json
)

---

## 🔧 Deployment Parameters

When you click **Deploy to Azure**, the Azure portal will prompt you for the following parameters.  
Only these **five parameters** are applicable to this template.

---

### 1️⃣ Subscription

**Description**  
The Azure subscription where the alert rule will be created and where Azure Resource Graph queries will be executed.

**Guidance**  
Choose the subscription that contains the workloads you want to monitor for **Azure Service Retirements**.

---

### 2️⃣ Resource Group

**Description**  
The resource group that will host the **Scheduled Query Rule (Log Alert)**.

**Guidance**  
Use a centralized monitoring or platform operations resource group for better governance and lifecycle management.

---

### 3️⃣ Region

**Description**  
The Azure region where the alert resource is deployed.

**Important**  
Although the alert resource is regional, the **query scope is subscription-wide** and not limited by region.

---

### 4️⃣ `scheduledqueryrules_alert_name`

**Description**  
The name of the **Azure Monitor Scheduled Query Rule**.

**Default value**
```text
alert-azureserviceretirements-01
