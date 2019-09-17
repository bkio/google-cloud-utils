#Burak Kara - Based on https://codelabs.developers.google.com/codelabs/vault-on-gke/index.html

# Disable exit on non 0
set +e

#
#Configuration Starts
#
export vaultClusterLocation="europe-north1"
export vaultVmType="g1-small"
export vaultDeploymentName="backend-vault"

#Set to false if the applications cluster already exists
export createApplicationsCluster=true
export applicationsDeploymentName="backend-apps"
export applicationsVmType="g1-small"
export applicationsClusterLocation="europe-north1"
#
#Configuration Ends
#

export gkeLatestMasterVersion=$(gcloud container get-server-config \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --region="${vaultClusterLocation}" \
      --format='value(validMasterVersions[0])')
export gkeLatestNodeVersion=$(gcloud container get-server-config \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --region="${vaultClusterLocation}" \
      --format='value(validNodeVersions[0])')
export gkeApplicationsClusterNamePrefix="gke_${GOOGLE_CLOUD_PROJECT}_${applicationsClusterLocation}"
export gkeVaultClusterNamePrefix="gke_${GOOGLE_CLOUD_PROJECT}_${vaultClusterLocation}"

#install vault
docker run -v $HOME/bin:/software sethvargo/hashicorp-installer vault 1.1.2
sudo chown -R $(whoami):$(whoami) $HOME/bin/vault
sudo chmod +x $HOME/bin/vault
export PATH=$HOME/bin:$PATH
vault -autocomplete-install || true

#create bucket for vault
gsutil mb "gs://${GOOGLE_CLOUD_PROJECT}-vault-storage"

#enable the Google Cloud KMS API:
gcloud services enable \
    cloudapis.googleapis.com \
    cloudkms.googleapis.com \
    cloudresourcemanager.googleapis.com \
    cloudshell.googleapis.com \
    container.googleapis.com \
    containerregistry.googleapis.com \
    iam.googleapis.com

#create a crypto key ring for Vault and a crypto key for the vault-init service
gcloud kms keyrings create vault \
	--project "${GOOGLE_CLOUD_PROJECT}" \
    --location ${vaultClusterLocation}
gcloud kms keys create vault-init \
	--project "${GOOGLE_CLOUD_PROJECT}" \
    --location ${vaultClusterLocation} \
    --keyring vault \
    --purpose encryption

#create the service account without permissions
export SERVICE_ACCOUNT="vault-server@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com"
gcloud iam service-accounts create vault-server \
	--project "${GOOGLE_CLOUD_PROJECT}" \
    --display-name "vault service account"

#grant the service account the ability to encrypt and decrypt data from the crypto key, this is required to use the Vault GCP secrets engine, otherwise it can be omitted.
ROLES=(
  "roles/resourcemanager.projectIamAdmin"
  "roles/iam.serviceAccountAdmin"
  "roles/iam.serviceAccountKeyAdmin"
  "roles/iam.serviceAccountTokenCreator"
  "roles/iam.serviceAccountUser"
  "roles/viewer"
  "roles/cloudkms.cryptoKeyEncrypterDecrypter"
)
for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${GOOGLE_CLOUD_PROJECT}" \
    --member "serviceAccount:${SERVICE_ACCOUNT}" \
    --role "${role}"
done

#grant the service account full access to all objects in the storage bucket
gsutil iam ch \
    "serviceAccount:${SERVICE_ACCOUNT}:objectAdmin" \
    "serviceAccount:${SERVICE_ACCOUNT}:legacyBucketReader" \
    "gs://${GOOGLE_CLOUD_PROJECT}-vault-storage"

#enable the GKE container API on GCP:
gcloud services enable container.googleapis.com

#creating a vault cluster
gcloud container clusters create vault \
  --cluster-version "${gkeLatestMasterVersion}" \
  --enable-autorepair \
  --enable-autoupgrade \
  --enable-ip-alias \
  --machine-type ${vaultVmType} \
  --node-version "${gkeLatestNodeVersion}" \
  --num-nodes 1 \
  --min-nodes 1 \
  --max-nodes 3 \
  --enable-autoscaling \
  --region ${vaultClusterLocation} \
  --scopes cloud-platform \
  --service-account "${SERVICE_ACCOUNT}" \
  --tags=${vaultDeploymentName}

#[!-TMP solution for dev-!] create a public IP
#NOTE: Do not do this for production!
gcloud compute addresses create vault --region ${vaultClusterLocation}
export vaultLBIP=$(gcloud compute addresses describe vault \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --region="${vaultClusterLocation}" \
      --format='value(address)')

#create certificates, variables and folder
export LB_IP="$(gcloud compute addresses describe vault --region ${vaultClusterLocation} --format 'value(address)')"
export DIR="$(pwd)/tls"
rm -rf $DIR
mkdir -p $DIR

#create the OpenSSL configuration file
sudo cat > "${DIR}/openssl.cnf" << EOF
[req]
default_bits = 2048
encrypt_key  = no
default_md   = sha256
prompt       = no
utf8         = yes

distinguished_name = req_distinguished_name
req_extensions     = v3_req

[req_distinguished_name]
C  = NO
ST = Oslo
L  = Oslo
O  = IX3
CN = vault

[v3_req]
basicConstraints     = CA:FALSE
subjectKeyIdentifier = hash
keyUsage             = digitalSignature, keyEncipherment
extendedKeyUsage     = clientAuth, serverAuth
subjectAltName       = @alt_names

[alt_names]
IP.1  = ${LB_IP}
DNS.1 = vault.default.svc.cluster.local
EOF

#generate Vault's certificate and certificate signing request (CSR)
openssl genrsa -out "${DIR}/vault.key" 2048
openssl req \
    -new -key "${DIR}/vault.key" \
    -out "${DIR}/vault.csr" \
    -config "${DIR}/openssl.cnf"
	
#create a Certificate Authority (CA):
openssl req \
    -new \
    -newkey rsa:2048 \
    -days 120 \
    -nodes \
    -x509 \
    -subj "/C=NO/ST=Oslo/L=Oslo/O=Vault CA" \
    -keyout "${DIR}/ca.key" \
    -out "${DIR}/ca.crt"
	
#sign the CSR with the CA:
openssl x509 \
    -req \
    -days 120 \
    -in "${DIR}/vault.csr" \
    -CA "${DIR}/ca.crt" \
    -CAkey "${DIR}/ca.key" \
    -CAcreateserial \
    -extensions v3_req \
    -extfile "${DIR}/openssl.cnf" \
    -out "${DIR}/vault.crt"
	
#combine the CA and Vault certificate (this is the format Vault expects):
cat "${DIR}/vault.crt" "${DIR}/ca.crt" > "${DIR}/vault-combined.crt"

#create configmap, the insecure data such as the Google Cloud Storage bucket name and IP address are placed in a Kubernetes configmap
kubectl create configmap vault \
	--cluster="${gkeVaultClusterNamePrefix}_vault" \
	--from-literal "load_balancer_address=${vaultLBIP}" \
	--from-literal "gcs_bucket_name=${GOOGLE_CLOUD_PROJECT}-vault-storage" \
	--from-literal "kms_project=${GOOGLE_CLOUD_PROJECT}" \
	--from-literal "kms_region=${vaultClusterLocation}" \
	--from-literal "kms_key_ring=vault" \
	--from-literal "kms_crypto_key=vault-init" \
	--from-literal="kms_key_id=projects/${GOOGLE_CLOUD_PROJECT}/locations/${vaultClusterLocation}/keyRings/vault/cryptoKeys/vault-init"

#secure data like the TLS certificates are put in a Kubernetes secret
kubectl create secret generic vault-tls \
	--cluster="${gkeVaultClusterNamePrefix}_vault" \
	--from-file "${DIR}/ca.crt" \
    --from-file "vault.crt=${DIR}/vault-combined.crt" \
    --from-file "vault.key=${DIR}/vault.key"
	
#apply the Kubernetes configuration file for Vault
kubectl apply -f "https://raw.githubusercontent.com/bkio/google-cloud-utils/master/hashicorpVault.yaml" \
	--cluster="${gkeVaultClusterNamePrefix}_vault"

#Vault is running, it is not available.
#We have not mapped the public IP address allocated earlier to the cluster. 
#To do this, we need to create a LoadBalancer service in Kubernetes.
#Vault is listening on port 8200 while the load balancer is listening on 443
#Vault's default port is 8200 and this is recommended for consistency.
#However, many corporate proxies don't allow outbound connections on random ports.
#Therefore, to make this codelab accessible to everyone, the load balancer serves traffic on 443 and routes the request to the Vault server on 8200.
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  labels:
    app: vault
spec:
  type: LoadBalancer
  loadBalancerIP: ${LB_IP}
  externalTrafficPolicy: Local
  selector:
    app: vault
  ports:
  - name: vault-port
    port: 443
    targetPort: 8200
    protocol: TCP
EOF

#Now The HashiCorp Vault servers are running in high availability mode on GKE.
#They are storing their data in Google Cloud Storage and they are auto-unsealed with keys encrypted with Google Cloud KMS.
#All the nodes are load balanced with a load balancer.

#Path to the CA certificate on disk:
export VAULT_CACERT="$(pwd)/tls/ca.crt"

#Generally we want to run Vault in a dedicated Kubernetes cluster or at least a dedicated namespace with tightly controlled RBAC permissions.
#To follow this best practice, create another Kubernetes cluster which will host our applications.
if [ "$createApplicationsCluster" = true ] ; then
    gcloud container clusters create ${applicationsDeploymentName} \
		--cluster-version "${gkeLatestMasterVersion}" \
		--enable-cloud-logging \
		--enable-cloud-monitoring \
		--enable-ip-alias \
		--no-enable-basic-auth \
		--no-issue-client-certificate \
		--machine-type ${applicationsVmType} \
		--num-nodes 1 \
		--min-nodes 1 \
		--max-nodes 3 \
		--enable-autoscaling \
		--region ${applicationsClusterLocation} \
		--tags=${applicationsDeploymentName}
fi
#This cluster does not have an attached service account. This is expected, because it doesn't need to talk to GCS or KMS directly.

#In our cluster, services will authenticate to Vault using the Kubernetes auth method
#For this, create the Kubernetes service account
kubectl create serviceaccount vault-auth

#Next, grant that service account the ability to access the TokenReviewer API via RBAC:
kubectl apply -f - <<EOH
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: default
EOH

#Applications cluster full name
export CLUSTER_NAME="${gkeApplicationsClusterNamePrefix}_${applicationsDeploymentName}"

#In this auth method, pods or services present their signed JWT token to Vault.
#Vault verifies the JWT token using the Token Reviewer API, and, if successful, Vault returns a token to the requestor.
#This process requires Vault to be able to talk to the Token Reviewer API in our cluster, 
#which is where the service account with RBAC permissions is important from the previous steps.
#For this, we must gather some environment variables
export SECRET_NAME="$(kubectl get serviceaccount vault-auth \
    -o go-template='{{ (index .secrets 0).name }}')"
	
export TR_ACCOUNT_TOKEN="$(kubectl get secret ${SECRET_NAME} \
    -o go-template='{{ .data.token }}' | base64 --decode)"
	
export K8S_HOST="$(kubectl config view --raw \
    -o go-template="{{ range .clusters }}{{ if eq .name \"${CLUSTER_NAME}\" }}{{ index .cluster \"server\" }}{{ end }}{{ end }}")"
	
export K8S_CACERT="$(kubectl config view --raw \
    -o go-template="{{ range .clusters }}{{ if eq .name \"${CLUSTER_NAME}\" }}{{ index .cluster \"certificate-authority-data\" }}{{ end }}{{ end }}" | base64 --decode)"
	
#Next, enable the Kubernetes auth method on Vault:
vault auth enable kubernetes

#Configure Vault to talk to the Applications Kubernetes cluster with the service account created earlier.
vault write auth/kubernetes/config \
    kubernetes_host="${K8S_HOST}" \
    kubernetes_ca_cert="${K8S_CACERT}" \
    token_reviewer_jwt="${TR_ACCOUNT_TOKEN}"

#Create a configmap to store the address of the Vault server. This is how pods and services will talk to Vault. 
kubectl create configmap vault \
    --from-literal "vault_addr=https://${LB_IP}"
	
#Lastly, create a Kubernetes secret to hold the Certificate Authority. This will be used by all pods and services talking to Vault to verify it's TLS connection.
kubectl create secret generic vault-tls \
    --from-file ${VAULT_CACERT}
	
#Vault is now configured to talk to the Applications Kubernetes cluster.
#Apps and services will be able to authenticate using the Vault Kubernetes Auth Method to access Vault secrets.
#At this point, our pods and services can authenticate to Vault, but their authentication will not have any authorization.
#That's because in Vault, everything is deny by default.

#Create a Vault policy named applications-vault-rw that grants read and list permission on the data
#When a user is assigned this policy, they will have the ability to perform CRUD operations on our key
vault policy write applications-vault-rw - <<EOH
path "kv/applications/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOH

#We need to map these policies to the Kubernetes authentication we enabled in the previous step.
vault write auth/kubernetes/role/applications-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default,applications-vault-rw \
    ttl=15m