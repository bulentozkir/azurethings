# Legacy VM Capacity Readiness

Deploy the workbook to an existing Azure resource group:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbulentozkir%2Fazurethings%2Fmain%2Fworkbooks%2Fdeploy-vm-capacity-readiness-workbook.json)

The deployment creates one shared `Microsoft.Insights/workbooks` resource in the
selected resource group. Redeploying to the same resource group updates the same
workbook. The template is self-contained and does not require PowerShell, Azure CLI,
or any local build step.

## Requirements

- Permission to create workbook resources in the target resource group, such as
  **Workbook Contributor** or **Contributor**.
- **Reader** access to the subscriptions inspected by the workbook.

## Source

- [Workbook JSON](https://github.com/bulentozkir/azurethings/blob/main/workbooks/vm-capacity-readiness-workbook.json)
- [Deployment template](https://github.com/bulentozkir/azurethings/blob/main/workbooks/deploy-vm-capacity-readiness-workbook.json)
