#!/bin/bash

# Configuration
CLUSTER_ID="sockshop-docdb-cluster"
INSTANCE_ID="sockshop-docdb-instance"
DB_USERNAME="username"
ENGINE_VERSION="5.0"
INSTANCE_CLASS="db.t3.medium"
REGION="us-east-1"
PORT=27017

# Vérification que DB_PASSWORD est défini
if [ -z "$DB_PASSWORD" ]; then
    echo "Erreur : la variable DB_PASSWORD n'est pas définie."
    echo "Veuillez exporter DB_PASSWORD avant de lancer le script."
    echo "Exemple : export DB_PASSWORD=votre-mot-de-passe-securise"
    exit 1
fi

# Récupérer le VPC et les sous-réseaux du cluster EKS
echo "Récupération des informations du cluster EKS pour le VPC..."
EKS_VPC_ID=$(aws eks describe-cluster \
  --name db-sockshop-cluster \
  --region "$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

if [ -z "$EKS_VPC_ID" ]; then
    echo "Erreur : impossible de récupérer le VPC du cluster EKS 'db-sockshop-cluster'."
    exit 1
fi

# Récupérer les sous-réseaux privés du VPC et leurs AZs
echo "Récupération des sous-réseaux privés du VPC $EKS_VPC_ID..."
SUBNETS_INFO=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$EKS_VPC_ID" \
  --region "$REGION" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`].[SubnetId,AvailabilityZone]' \
  --output json)

if [ -z "$SUBNETS_INFO" ] || [ "$SUBNETS_INFO" == "[]" ]; then
    echo "Erreur : aucun sous-réseau privé trouvé dans le VPC $EKS_VPC_ID."
    exit 1
fi

# Extraire les sous-réseaux et vérifier le nombre d'AZs
SUBNET_IDS=()
AZS=()
while IFS=$'\t' read -r subnet_id az; do
    SUBNET_IDS+=("$subnet_id")
    if [[ ! " ${AZS[*]} " =~ " $az " ]]; then
        AZS+=("$az")
    fi
done < <(echo "$SUBNETS_INFO" | jq -r '.[] | [.[]] | join("\t")')

# Vérifier qu'il y a au moins 2 AZs
if [ ${#AZS[@]} -lt 2 ]; then
    echo "Erreur : les sous-réseaux privés ne couvrent pas au moins 2 zones de disponibilité (AZs). AZs trouvées : ${AZS[*]}"
    echo "DocumentDB exige des sous-réseaux dans au moins 2 AZs pour la haute disponibilité."
    exit 1
fi

# Convertir SUBNET_IDS en une chaîne pour la commande AWS
SUBNET_IDS_STR=$(IFS=" "; echo "${SUBNET_IDS[*]}")

echo "Sous-réseaux privés trouvés : $SUBNET_IDS_STR (AZs : ${AZS[*]})"

# Récupérer le SG principal du cluster EKS
EKS_SG=$(aws eks describe-cluster \
  --name db-sockshop-cluster \
  --region "$REGION" \
  --query "cluster.resourcesVpcConfig.securityGroupIds[0]" \
  --output text)

# Vérifier si le Security Group DocumentDB existe déjà
echo "Vérification de l'existence du Security Group 'sockshop-docdb-sg'..."
DOCDB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=sockshop-docdb-sg" "Name=vpc-id,Values=$EKS_VPC_ID" \
  --region "$REGION" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

if [ "$DOCDB_SG" == "None" ] || [ -z "$DOCDB_SG" ]; then
    echo "Création du Security Group pour DocumentDB..."
    DOCDB_SG=$(aws ec2 create-security-group \
        --group-name "sockshop-docdb-sg" \
        --description "Security group for SockShop DocumentDB" \
        --vpc-id "$EKS_VPC_ID" \
        --region "$REGION" \
        --query 'GroupId' \
        --output text)
else
    echo "Le Security Group 'sockshop-docdb-sg' existe déjà (ID: $DOCDB_SG). Saut de la création."
fi

# Autoriser le trafic EKS → DocumentDB (ignorer si déjà autorisé)
aws ec2 authorize-security-group-ingress \
  --group-id "$DOCDB_SG" \
  --protocol tcp \
  --port "$PORT" \
  --source-group "$EKS_SG" \
  --region "$REGION" 2>/dev/null || echo "🔒 Règle d'accès déjà présente ou non nécessaire, poursuite..."

# Vérifier si le DB Subnet Group existe
echo "Vérification de l'existence du DB Subnet Group pour DocumentDB..."
if ! aws docdb describe-db-subnet-groups \
    --region "$REGION" \
    --query "DBSubnetGroups[?DBSubnetGroupName=='sockshop-docdb-subnet-group']" \
    --output text | grep -q "sockshop-docdb-subnet-group"; then

    echo "Création du DB Subnet Group pour DocumentDB..."
    aws docdb create-db-subnet-group \
        --db-subnet-group-name "sockshop-docdb-subnet-group" \
        --db-subnet-group-description "Subnet group for SockShop DocumentDB" \
        --subnet-ids $SUBNET_IDS_STR \
        --region "$REGION" || {
        echo "Erreur : échec de la création du DB Subnet Group."
        exit 1
    }
else
    echo "Le DB Subnet Group 'sockshop-docdb-subnet-group' existe déjà. Saut de la création."
fi

# Création du cluster DocumentDB si nécessaire
if aws docdb describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --region "$REGION" &> /dev/null; then
    echo "Le cluster DocumentDB '$CLUSTER_ID' existe déjà. Saut de la création."
else
    echo "Création du cluster DocumentDB '$CLUSTER_ID'..."
    aws docdb create-db-cluster \
        --db-cluster-identifier "$CLUSTER_ID" \
        --engine docdb \
        --engine-version "$ENGINE_VERSION" \
        --master-username "$DB_USERNAME" \
        --master-user-password "$DB_PASSWORD" \
        --db-subnet-group-name "sockshop-docdb-subnet-group" \
        --vpc-security-group-ids "$DOCDB_SG" \
        --port "$PORT" \
        --region "$REGION" || {
        echo "Erreur : échec de la création du cluster DocumentDB."
        exit 1
    }

    echo "En attente de la disponibilité du cluster DocumentDB..."
    until aws docdb describe-db-clusters \
        --db-cluster-identifier "$CLUSTER_ID" \
        --region "$REGION" \
        --query "DBClusters[0].Status" \
        --output text | grep -q "available"; do
        echo "Cluster en cours de création, attente 30 secondes..."
        sleep 30
    done
    echo "Cluster disponible !"
fi

# Création de l'instance DocumentDB
if aws docdb describe-db-instances --db-instance-identifier "$INSTANCE_ID" --region "$REGION" &> /dev/null; then
    echo "L'instance DocumentDB '$INSTANCE_ID' existe déjà. Saut de la création."
else
    echo "Création de l'instance DocumentDB '$INSTANCE_ID'..."
    aws docdb create-db-instance \
        --db-instance-identifier "$INSTANCE_ID" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --db-instance-class "$INSTANCE_CLASS" \
        --engine docdb \
        --region "$REGION" || {
        echo "Erreur : échec de la création de l'instance DocumentDB."
        exit 1
    }

    echo "En attente de la disponibilité de l'instance DocumentDB..."
    aws docdb wait db-instance-available \
        --db-instance-identifier "$INSTANCE_ID" \
        --region "$REGION"
fi

echo "C'est BON! Le cluster DocumentDB '$CLUSTER_ID' et l'instance '$INSTANCE_ID' sont prêts."