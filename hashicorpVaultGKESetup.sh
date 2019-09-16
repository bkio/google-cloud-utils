#Burak Kara - Based on https://codelabs.developers.google.com/codelabs/vault-on-gke/index.html
#Check commands starts with "NOTE:" comment line!

# Disable exit on non 0
set +e

#set cluster location
#NOTE: Change this to your desired location
export clusterLocation="europe-north1"
export vmType="g1-small"
export deploymentName="backend-pn"

export gkeLatestMasterVersion=$(gcloud container get-server-config \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --region="${clusterLocation}" \
      --format='value(validMasterVersions[0])')
export gkeLatestNodeVersion=$(gcloud container get-server-config \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --region="${clusterLocation}" \
      --format='value(validNodeVersions[0])')
export gkeClusterNamePrefix="gke_${GOOGLE_CLOUD_PROJECT}_${clusterLocation}"

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
    --location ${clusterLocation}
gcloud kms keys create vault-init \
	--project "${GOOGLE_CLOUD_PROJECT}" \
    --location ${clusterLocation} \
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

#creating a cluster
gcloud container clusters create vault \
  --cluster-version "${gkeLatestMasterVersion}" \
  --enable-autorepair \
  --enable-autoupgrade \
  --enable-ip-alias \
  --machine-type ${vmType} \
  --node-version "${gkeLatestNodeVersion}" \
  --num-nodes 1 \
  --region ${clusterLocation} \
  --scopes cloud-platform \
  --service-account "${SERVICE_ACCOUNT}" \
  --min-nodes 1 \
  --max-nodes 3 \
  --enable-autoscaling \
  --tags=${deploymentName}

#[!-TMP solution for dev-!] create a public IP
#NOTE: Do not do this for production!
gcloud compute addresses create vault --region ${clusterLocation}
export vaultLBIP=$(gcloud compute addresses describe vault \
      --project="${GOOGLE_CLOUD_PROJECT}" \
      --region="${clusterLocation}" \
      --format='value(address)')

#create certificates, variables and folder
export LB_IP="$(gcloud compute addresses describe vault --region ${clusterLocation} --format 'value(address)')"
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
	--cluster="${gkeClusterNamePrefix}_vault" \
	--from-literal "load_balancer_address=${vaultLBIP}" \
	--from-literal "gcs_bucket_name=${GOOGLE_CLOUD_PROJECT}-vault-storage" \
	--from-literal "kms_project=${GOOGLE_CLOUD_PROJECT}" \
	--from-literal "kms_region=${clusterLocation}" \
	--from-literal "kms_key_ring=vault" \
	--from-literal "kms_crypto_key=vault-init" \
	--from-literal="kms_key_id=projects/${GOOGLE_CLOUD_PROJECT}/locations/${clusterLocation}/keyRings/vault/cryptoKeys/vault-init"

#secure data like the TLS certificates are put in a Kubernetes secret
kubectl create secret generic vault-tls \
	--cluster="${gkeClusterNamePrefix}_vault" \
	--from-file "${DIR}/ca.crt" \
    --from-file "vault.crt=${DIR}/vault-combined.crt" \
    --from-file "vault.key=${DIR}/vault.key"
	
#apply the Kubernetes configuration file for Vault
kubectl apply -f "https://raw.githubusercontent.com/sethvargo/vault-kubernetes-workshop/master/k8s/vault.yaml" \
	--cluster="${gkeClusterNamePrefix}_vault"

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

#IP of the load balancer
export VAULT_ADDR="https://${LB_IP}:443"

#Path to the CA certificate on disk:
export VAULT_CACERT="$(pwd)/tls/ca.crt"

#Decrypted root token:
export VAULT_TOKEN="$(gsutil cat "gs://${GOOGLE_CLOUD_PROJECT}-vault-storage/root-token.enc" | \
  base64 --decode | \
  gcloud kms decrypt \
    --location ${clusterLocation} \
    --keyring vault \
    --key vault-init \
    --ciphertext-file - \
    --plaintext-file -)"
