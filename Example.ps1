# Built to run in PowerShell

$location="eastus" # Set to preferred Azure Region
$randoseed=(get-random -min 100 -max 999)
$KV ="ankv"+$randoseed
$aksname="aks-test"+$randoseed
$rg="AKS-test"+$randoseed
$law="law"+$randoseed
$sub="490aa666-a16d-458c-9878-84f5ea424bc8" # Set your subscription ID here
$myip=curl -4 ifconfig.io/ip
$tenantId=az account show --query tenantId --output tsv # Used to customize secrets provider class

az login
az account set --subscription $sub

# Create a resource group
az group create --name $rg --location $location

# Create a Log Analytics workspace
az monitor log-analytics workspace create `
    --resource-group $rg `
    --workspace-name $law `
    --location $location `
    --no-wait

# Get the Log Analytics workspace ID
$lawid=(az monitor log-analytics workspace show --resource-group $rg --workspace-name $law --query id -o tsv)

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

# Create a Key Vault with RBAC enabled
az keyvault create `
    --location $location `
    --name $KV `
    --resource-group $rg `
    --enable-rbac-authorization `
    --no-wait

# Managed identity for KV provider
$miKV_Client=(az aks show -g $rg -n $aksname --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv) #Needed for SecretProvideClass.Yaml
$miKV_Object=(az aks show -g $rg -n $aksname --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)

# Get Key Vault ID
$KV_ID=(az keyvault show --name $KV --resource-group $rg --query id -o tsv)
$KV_Admin=(az role definition list --query "[?roleName=='Key Vault Administrator'].{roleName:name}" --output tsv)
$KV_Cert=(az role definition list --query "[?roleName=='Key Vault Certificate User'].{roleName:name}" --output tsv)

# My ID cause it's an external tenant
$userKV_Admin=(az ad user list --filter "mail eq 'anevico@microsoft.com'" --query "[].id" -o tsv) #external tenant so a bit of hack to get my ID

# Add Myself as Key Vault Admin
az role assignment create --assignee $userKV_Admin --role $KV_Admin --scope $KV_ID

# Add MI as Key Vault Certificate Contributor
az role assignment create --assignee $miKV_Object --role $KV_Cert --scope $KV_ID

# Upload a cert
az keyvault certificate import --vault-name $KV --name "aks-ingress-cert" --file .\Certificate\aks-ingress-cert.pfx

# Get Creds
az aks get-credentials --resource-group AKS-test221 --name aks-test221 --overwrite-existing

# Validate Connectivity and that CSI is running
kubectl get pods --selector 'app in (csi-secrets-store-provider-azure, secrets-store-provider-azure)' `
    --all-namespaces `
    --output wide

# Kubectl commands
$NAMESPACE="ingress-sample"
kubectl create namespace $NAMESPACE

# Customize SecretsProvider Class using the file prior to deploying
kubectl apply -f .\Deployments\secretProviderClass.yaml -n ingress-sample

# Add the Ingress Nginx Helm Repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install Helm chart with custom ingress values
# Current values file is binding the certificate to the ingress controller
# helm install -f .\ingress-nginx-values.yaml ingress-nginx/ingress-nginx --generate-name --namespace $NAMESPACE --dry-run --debug > ./testrun-yaml # If you want to see what it will install
helm install -f ..\Deployments\ingress-nginx-values.yaml ingress-nginx/ingress-nginx --generate-name --namespace $namespace

# Confirm secret was mounted
kubectl get secret -n $namespace

# Deploy Hello World Apps
kubectl apply -f .\Deployments\aks-helloworldingress-one.yaml -n $NAMESPACE
kubectl apply -f .\Deployments\aks-helloworldingress-two.yaml -n $NAMESPACE

# Validate deployment scheduled
kubectl get deployments -n $NAMESPACE

# Deploy the ingress configuration
kubectl apply -f .\Deployments\aks-ingress.yaml -n $NAMESPACE

# Get External IP of the load balancer to build the curl command
$externalip=(kubectl get service --namespace $NAMESPACE --selector app.kubernetes.io/name=ingress-nginx -o "jsonpath={.items[0].status.loadBalancer.ingress[0].ip}")

# Test the ingress
curl -v -k --resolve demo.azure.com:443:$externalip https://demo.azure.com #test main resolution
curl -v -k --resolve demo.azure.com:443:$externalip https://demo.azure.com/hello-world-two #test path resolution

# Clean up
az group delete --name $rg --yes --no-wait

