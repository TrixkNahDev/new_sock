#!/bin/bash

# Variables
CLUSTER_NAME="db-sockshop-cluster"
REGION="us-east-1"
K8S_VERSION="1.29"  # Version de Kubernetes compatible avec EKS

# Vérifier si eksctl est installé
if ! command -v eksctl &> /dev/null; then
    echo "eksctl n'est pas installé. Installation en cours..."
    curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
    if ! command -v eksctl &> /dev/null; then
        echo "Erreur : échec de l'installation d'eksctl. Veuillez l'installer manuellement."
        exit 1
    fi
    echo "eksctl installé avec succès : $(eksctl version)"
fi

# Vérifier si aws CLI est installé
if ! command -v aws &> /dev/null; then
    echo "aws CLI n'est pas installé. Installation en cours..."
    sudo apt update
    sudo apt install -y awscli
    if ! command -v aws &> /dev/null; then
        echo "Erreur : échec de l'installation d'aws CLI."
        exit 1
    fi
    echo "aws CLI installé avec succès : $(aws --version)"
fi

# Vérifier si kubectl est installé
if ! command -v kubectl &> /dev/null; then
    echo "kubectl n'est pas installé. Installation en cours..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    if ! command -v kubectl &> /dev/null; then
        echo "Erreur : échec de l'installation de kubectl."
        exit 1
    fi
    echo "kubectl installé avec succès : $(kubectl version --client)"
fi

# Vérifier si Helm est installé
if ! command -v helm &> /dev/null; then
    echo "Helm n'est pas installé. Installation en cours..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    if ! command -v helm &> /dev/null; then
        echo "Erreur : échec de l'installation de Helm."
        exit 1
    fi
    echo "Helm installé avec succès : $(helm version --short)"
fi

# Vérifier si les identifiants AWS sont configurés
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Erreur : les identifiants AWS ne sont pas configurés."
    echo "Configurez-les avec 'aws configure' ou exportez AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, et AWS_DEFAULT_REGION."
    exit 1
fi


# Créer le cluster EKS si non existant
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
    echo "Le cluster '$CLUSTER_NAME' existe déjà. Saut de la création."
else
    echo "Création du cluster EKS '$CLUSTER_NAME' dans la région '$REGION'..."
    eksctl create cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --version "$K8S_VERSION" \
        --nodes 3 \
        --node-type t3.medium \
        --nodes-min 1 \
        --nodes-max 4

    # Vérifier si la création a réussi
    if [ $? -ne 0 ]; then
        echo "Erreur : échec de la création du cluster EKS. Vérifiez les permissions AWS, les quotas, ou les logs ci-dessus."
        exit 1
    fi
fi


# Vérifier si la création a réussi
if [ $? -ne 0 ]; then
    echo "Erreur : échec de la création du cluster EKS. Vérifiez les permissions AWS, les quotas, ou les logs ci-dessus."
    exit 1
fi

# Mettre à jour le kubeconfig
echo "Mise à jour du kubeconfig pour le cluster '$CLUSTER_NAME'..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
if [ $? -ne 0 ]; then
    echo "Erreur : échec de la mise à jour du kubeconfig."
    exit 1
fi

# Vérifier que kubectl peut se connecter au cluster
echo "Vérification de la connexion au cluster..."
kubectl cluster-info
if [ $? -ne 0 ]; then
    echo "Erreur : kubectl ne peut pas se connecter au cluster. Vérifiez la configuration."
    exit 1
fi

# Appliquer le chart Helm pour créer le secret aws-credentials
echo "Application du chart Helm 'database-backup' pour créer le secret aws-credentials..."
cd ~/sock_project/helm-charts/database-backup

# Vérifier si les identifiants AWS sont disponibles via variables d'environnement
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Erreur : les variables d'environnement AWS_ACCESS_KEY_ID et AWS_SECRET_ACCESS_KEY doivent être définies."
    echo "Exportez-les avant de continuer, par exemple :"
    echo "export AWS_ACCESS_KEY_ID=ton-access-key"
    echo "export AWS_SECRET_ACCESS_KEY=ton-secret-key"
    exit 1
fi

# Installer le chart Helm avec les identifiants AWS passés via --set
helm install database-backup . \
    --set aws.accessKeyId="$AWS_ACCESS_KEY_ID" \
    --set aws.secretAccessKey="$AWS_SECRET_ACCESS_KEY" \
    --namespace default

# Vérifier que le secret a été créé
echo "Vérification de la création du secret aws-credentials..."
kubectl get secrets aws-credentials
if [ $? -ne 0 ]; then
    echo "Erreur : le secret aws-credentials n'a pas été créé correctement."
    exit 1
fi

echo "Le cluster EKS '$CLUSTER_NAME' a été créé avec succès, le kubeconfig est mis à jour, et le secret aws-credentials est appliqué."