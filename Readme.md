# Sample Deployment of Azure Key Vault CSI Driver

Solution is built using a mix of Powershell and Azure CLI (went this route as the original article was built for WSL/Bash)
Deployed this interactively via VSCode
Original learn article available here - [CSI Driver Doc on Learn Site](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-nginx-tls)
This solution deploys the "Ingress bound" certificate option using the Cluster's Identity instead of Workload (Pod) managed identity.
Solid workload managed identity example here - [Using the Azure Key Vault CSI Driver with Workload Identity](https://azureglobalblackbelts.com/2024/03/05/workload-identity-kv-csi.html)

## Tools required

- [Azure-cli](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?tabs=winget#install-or-update)
- [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)
- [Helm](https://helm.sh/docs/intro/install/)
- [VSCode](https://code.visualstudio.com/)

## Quality of life improvements

- [Kubectx/Kubens](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)
- [K9s](https://k9scli.io/topics/install/)

## Get started deploying

Solution as defined will install/configure the an nginx ingress controller using a self signed certificated located in the `./Certificate` folder.
You can also leverage the shell script to generate your own.
Self signed certificates should never be used in production or production like environments

``` Powershell
$location="eastus" # Set to preferred Azure Region
$randoseed=(get-random -min 100 -max 999) #helps with uniqueness of values
$KV ="ankv"+$randoseed
$aksname="aks-test"+$randoseed
$rg="AKS-test"+$randoseed
$law="law"+$randoseed
$sub="490aa666-a16d-458c-9878-84f5ea424bc8" # Set your subscription ID here
$myip=curl -4 ifconfig.io/ip
$tenantId=az account show --query tenantId --output tsv # Used to customize secrets provider class
```

Login to the Tenant

``` Powershell
az login
az account set --subscription $sub
```

Create a resource group

```powershell
# Create a resource group
az group create --name $rg --location $location
```

Create a log analytics workspace (alternatively substitute an existing workspace )

```powershell
# Create a Log Analytics workspace
az monitor log-analytics workspace create `
    --resource-group $rg `
    --workspace-name $law `
    --location $location `
    --no-wait
```

Next will grab the workspace ID to pass into the AKS creation command

```powershell
# Get the Log Analytics workspace ID
$lawid=(az monitor log-analytics workspace show --resource-group $rg --workspace-name $law --query id -o tsv)
```

Create an AKS cluster.  This is deploying a single node, rapid updating, free tier cluster public cluster.
It uses Azure Linux and the Azure CNI with overlay for networking
It includes Cluster Insights and the CNI driver.
Cluster is not production ready, but suitable for testing

```powershell
# Create an AKS cluster
az aks create `
    --resource-group $rg `
    --name $aksname `
    --node-count 1 `
    --enable-addons monitoring, azure-keyvault-secrets-provider `
    --enable-oidc-issuer `
    --enable-secret-rotation `
    --enable-managed-identity `
    --generate-ssh-keys `
    --location $location `
    --api-server-authorized-ip-ranges $myip `
    --auto-upgrade-channel rapid `
    --node-os-upgrade-channel nodeimage `
    --network-plugin azure `
    --network-plugin-mode overlay `
    --tier Free `
    --os-sku AzureLinux `
    --workspace-resource-id $lawid `
    --no-wait
```

Create an RBAC enabled Key Vault to deploy the certificate into (or leverage an existing KV)

```powershell
# Create a Key Vault with RBAC enabled
az keyvault create `
    --location $location `
    --name $KV `
    --resource-group $rg `
    --enable-rbac-authorization `
    --no-wait
```

Get values to import resources into Key Vault

```Powershell
# Get Key Vault ID
$KV_ID=(az keyvault show --name $KV --resource-group $rg --query id -o tsv)
$KV_Admin=(az role definition list --query "[?roleName=='Key Vault Administrator'].{roleName:name}" --output tsv) #Not for production demo only
$KV_Cert=(az role definition list --query "[?roleName=='Key Vault Certificate User'].{roleName:name}" --output tsv) #This is the properly permissioned role for the secrets provider to leverage certificates
```

For my demo environment I'm leveraging an external tenant which makes it less fun to search for users by name or UPN.
As a work around I'm searching for my user ID via email
I add myself as a Key Vault Admin to provide full permissions in order to upload the certificate (not recommended for production as that's over permissioned)

```powershell
# My ID cause it's an external tenant
$userKV_Admin=(az ad user list --filter "mail eq 'anevico@microsoft.com'" --query "[].id" -o tsv) #Change to your email address

# Add Myself as Key Vault Admin
az role assignment create --assignee $userKV_Admin --role $KV_Admin --scope $KV_ID
```

When you install the CSI Driver Addon for AKS it automatically creates a user assigned managed identity for the addon.  We need to get two values the MI's ObjectID (to be able to set permission in Key Vault) and the MI's Client ID as it's needed for the `SecretProviderClass.yaml` configuration

```powershell
# Managed identity for KV provider
$miKV_Client=(az aks show -g $rg -n $aksname --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv) #Needed for SecretProvideClass.Yaml
$miKV_Object=(az aks show -g $rg -n $aksname --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv) #Needed to add permissions

# Add MI as Key Vault Certificate Contributor
az role assignment create --assignee $miKV_Object --role $KV_Cert --scope $KV_ID

# Upload the cert
az keyvault certificate import --vault-name $KV --name "aks-ingress-cert" --file .\Certificate\aks-ingress-cert.pfx
```

Now Pivoting Over to AKS/Kubectl land.
For this demo I'm leveraging a public cluster with an ip whitelist and kubernetes native authentication.
For production style scenarios I'd recommend a private cluster and RBAC authentication, but neither is important for this demo

```powershell
# Get Creds
az aks get-credentials --resource-group $rg --name $aksname --overwrite-existing
```

We want to make sure that both our connectivity to the cluster is successful, and that the addon installed successfully.
The following command supports both (I'd expect to see an "Aks-secret-store-provider-azure-xxxx) name in the Kube-system namespace and 1/1 pods running

```powershell
# Validate Connectivity and that CSI is running
kubectl get pods --selector 'app in (csi-secrets-store-provider-azure, secrets-store-provider-azure)' `
    --all-namespaces `
    --output wide
```

Now we need to adjust a couple of values in our `SecretProviderClass.Yaml` file
At a minimum you'll need to set:

- `tenantID` which can be surfaced via the `$tenantId` variable
- `keyvaultName` which can be surfaced via the `$KV` variable
- `userAssignedIdentityID`: which can be surface via the `$miKV_Client` variable

Once these values are configured we can deploy the `SecretProviderClass.yaml`

```Powershell
# Kubectl commands
$NAMESPACE="ingress-sample"
kubectl create namespace $NAMESPACE

# Customize SecretsProvider Class using the file prior to deploying
kubectl apply -f .\Deployments\secretProviderClass.yaml -n ingress-sample
```

Next we'll pull down the Helm Chart to install nginx.
In the original example bash was used to inject values into the configuration.  In this example I generated a values template leveraging the `--dry-run` flag with Helm.

```yml
# Add the Ingress Nginx Helm Repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install Helm chart with custom ingress values
# Current values file is binding the certificate to the ingress controller
# helm install -f .\ingress-nginx-values.yaml ingress-nginx/ingress-nginx --generate-name --namespace $NAMESPACE --dry-run --debug > ./testrun-yaml # If you want to see what it will install
helm install -f .\Deployments\ingress-nginx-values.yaml ingress-nginx/ingress-nginx --generate-name --namespace $namespace
```
Next you'll want to ensure the secret was mounted successfully.  If you do not see an `ingress-tls-csi` (assuming you get the default) of type `kubernetes.io/tls` pause here and check your configs

``` yml
# Confirm the Secret was mounted successfully before continuing
kubectl get secret -n $namespace
```

Next we will deploy two hello world apps and an ingress configuration to interact with them.  These differ slightly from the original example as we've added some pod resource definitions as a best practice.

```yml
# Deploy Hello World Apps
kubectl apply -f .\Deployments\aks-helloworldingress-one.yaml -n $NAMESPACE
kubectl apply -f .\Deployments\aks-helloworldingress-two.yaml -n $NAMESPACE

# Validate deployment scheduled (you should see 2x deployments with 1/1 pod scheduled)
kubectl get deployments -n $NAMESPACE

# Deploy the ingress configuration
kubectl apply -f .\Deployments\aks-ingress.yaml -n $NAMESPACE
```

Once this is deployed we're ready to test the solution

```powershell
# Get External IP of the load balancer to build the curl command
$externalip=(kubectl get service --namespace $NAMESPACE --selector app.kubernetes.io/name=ingress-nginx -o "jsonpath={.items[0].status.loadBalancer.ingress[0].ip}")

# Test the ingress
curl -v -k --resolve demo.azure.com:443:$externalip https://demo.azure.com #test main resolution
curl -v -k --resolve demo.azure.com:443:$externalip https://demo.azure.com/hello-world-two #test path resolution
```

With that you're ready to clean up

```powershell
az group delete --name $rg --yes --no-wait
```

DISCLAIMER: Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment
unless thorough testing has been conducted by the app and database teams. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE. We grant You a nonexclusive, royalty-free right to
use and modify the Sample Code and to reproduce and distribute the object code form of the Sample Code, provided that. You agree: (i) to
not use Our name, logo, or trademarks to market Your software product in which the Sample Code is embedded; (ii) to include a valid
copyright notice on Your software product in which the Sample Code is embedded; and (iii) to indemnify, hold harmless, and defend Us and
Our suppliers from and against any claims or lawsuits, including attorneys’ fees, that arise or result from the use or distribution or use of the
Sample Code

### Reference

- [Nginx Helm Chart](https://docs.nginx.com/nginx-ingress-controller/installation/installing-nic/installation-with-helm/)
- [Helm Debugging](https://helm.sh/docs/chart_template_guide/debugging/)
- [Troubleshooting Secrets Store CSI Driver](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/extensions/troubleshoot-key-vault-csi-secrets-store-csi-driver)