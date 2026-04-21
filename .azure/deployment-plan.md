Status: Ready for Validation

# Deployment Plan

## Mode
- Modify existing Terraform-managed Azure Function App.

## Goals
- Fix Azure Functions package layout and dependency installation.
- Fix Terraform deployment so the package is actually mounted by the Function App.
- Prevent the function from breaking its own runtime storage account firewall.
- Make the timer trigger configuration valid and observable.

## Planned Changes
- Restructure the function project into a valid Azure Functions Python layout.
- Rename and retain the Python dependency manifest as requirements.txt.
- Update host.json to include the extension bundle needed for timer triggers.
- Update Terraform to deploy the package from a blob URL with SAS and remove the broken slot-based deployment path.
- Add an explicit target storage account variable so the function updates the intended storage firewall instead of the host storage account.
- Update documentation to reflect the corrected deployment and configuration model.

## Validation
- Run Terraform validation against the updated configuration.
- Run Python syntax validation on the function code.
- Inspect the generated zip artifact layout.

## Completed
- Function project restructured to a valid Azure Functions Python layout.
- Timer trigger schedule corrected to run every 5 minutes.
- Extension bundle added for timer trigger binding resolution.
- Terraform package deployment updated to use the Function App package URL directly.
- Broken deployment slot removed.
- Runtime authentication switched to the Function App managed identity.
- Target storage account configuration made explicit to avoid self-lockout.
- Terraform configuration validated successfully.
- Package layout verified successfully.

## Risks
- Existing deployments may currently rely on the accidental self-targeting storage account behavior.
- Key Vault and role assignment propagation can still delay first successful execution after deployment.