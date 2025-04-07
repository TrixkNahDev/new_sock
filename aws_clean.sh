#!/bin/bash

set -euo pipefail

echo "🔍 Début du nettoyage des ressources AWS..."

# Vérifier que l'utilisateur a les permissions nécessaires
echo "🔐 Vérification des permissions AWS..."
aws sts get-caller-identity > /dev/null || {
  echo "❌ Erreur : Impossible de vérifier les permissions AWS. Assurez-vous que vos credentials sont configurées et que vous avez les permissions nécessaires."
  exit 1
}

# Récupérer toutes les régions
regions=$(aws ec2 describe-regions --query "Regions[*].RegionName" --output text)
if [ -z "$regions" ]; then
  echo "❌ Erreur : Impossible de lister les régions AWS."
  exit 1
fi

# Supprimer les buckets S3 (en dehors de la boucle des régions, car S3 est global)
echo "🔹 Suppression des buckets S3 (sockshop)..."
for bucket in sockshop-mysql-backup sockshop-mongo-backup sockshop-redis-backup; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "   ➤ Suppression du bucket S3: $bucket"
    aws s3 rb "s3://$bucket" --force || {
      echo "   ⚠️ Échec de la suppression du bucket $bucket. Vérifiez les permissions ou s'il est déjà supprimé."
    }
  else
    echo "   ℹ️ Bucket $bucket n'existe pas, passage..."
  fi
done

for region in $regions; do
  echo "🌍 Région en cours: $region"

  # Suppression des clusters EKS
  echo "🔹 Suppression des clusters EKS..."
  for cluster in $(aws eks list-clusters --region "$region" --query "clusters[]" --output text); do
    echo "   ➤ Suppression du cluster EKS: $cluster"
    eksctl delete cluster --name "$cluster" --region "$region" --wait || {
      echo "   ⚠️ Échec de la suppression du cluster EKS $cluster via eksctl. Tentative de suppression manuelle des stacks CloudFormation..."
    }
  done

  # Suppression des stacks CloudFormation résiduelles pour les clusters EKS
  echo "🔹 Suppression des stacks CloudFormation résiduelles pour EKS..."
  for stack in $(aws cloudformation describe-stacks --region "$region" --query "Stacks[?starts_with(StackName, 'eksctl-')].StackName" --output text); do
    echo "   ➤ Suppression de la stack CloudFormation: $stack"
    aws cloudformation delete-stack --stack-name "$stack" --region "$region" || {
      echo "   ⚠️ Échec de la suppression de la stack $stack. Vérifiez les dépendances ou les permissions."
    }
    # Attendre que la stack soit supprimée
    echo "   ⏳ Attente de la suppression de la stack $stack..."
    aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$region" || {
      echo "   ⚠️ La stack $stack n'a pas pu être supprimée complètement. Vérifiez les logs CloudFormation."
    }
  done

  # Suppression des instances DocumentDB (avant les clusters)
  echo "🔹 Suppression des instances DocumentDB..."
  for db in $(aws docdb describe-db-instances --region "$region" --query "DBInstances[*].DBInstanceIdentifier" --output text); do
    echo "   ➤ Suppression de l’instance DocumentDB: $db"
    aws docdb delete-db-instance --db-instance-identifier "$db" --region "$region" || {
      echo "   ⚠️ Échec de la suppression de l’instance DocumentDB $db."
    }
    # Attendre que l’instance soit supprimée
    echo "   ⏳ Attente de la suppression de l’instance DocumentDB $db..."
    aws docdb wait db-instance-deleted --db-instance-identifier "$db" --region "$region" || true
  done

  # Suppression des clusters DocumentDB
  echo "🔹 Suppression des clusters DocumentDB..."
  for cluster in $(aws docdb describe-db-clusters --region "$region" --query "DBClusters[*].DBClusterIdentifier" --output text); do
    echo "   ➤ Suppression du cluster DocumentDB: $cluster"
    aws docdb delete-db-cluster --db-cluster-identifier "$cluster" --region "$region" --skip-final-snapshot || {
      echo "   ⚠️ Échec de la suppression du cluster DocumentDB $cluster."
    }
    # Attendre que le cluster soit supprimé
    echo "   ⏳ Attente de la suppression du cluster DocumentDB $cluster..."
    aws docdb wait db-cluster-deleted --db-cluster-identifier "$cluster" --region "$region" || true
  done

  # Suppression des DB Subnet Groups pour DocumentDB
  echo "🔹 Suppression des DB Subnet Groups pour DocumentDB..."
  for subnet_group in $(aws docdb describe-db-subnet-groups --region "$region" --query "DBSubnetGroups[*].DBSubnetGroupName" --output text); do
    echo "   ➤ Suppression du DB Subnet Group: $subnet_group"
    aws docdb delete-db-subnet-group --db-subnet-group-name "$subnet_group" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du DB Subnet Group $subnet_group."
    }
  done

  # Suppression des instances RDS
  echo "🔹 Suppression des instances RDS..."
  for db in $(aws rds describe-db-instances --region "$region" --query "DBInstances[*].DBInstanceIdentifier" --output text); do
    echo "   ➤ Suppression de l’instance RDS: $db"
    aws rds delete-db-instance --db-instance-identifier "$db" --region "$region" --skip-final-snapshot || {
      echo "   ⚠️ Échec de la suppression de l’instance RDS $db."
    }
    # Attendre que l’instance soit supprimée
    echo "   ⏳ Attente de la suppression de l’instance RDS $db..."
    aws rds wait db-instance-deleted --db-instance-identifier "$db" --region "$region" || true
  done

  # Suppression des DB Subnet Groups pour RDS
  echo "🔹 Suppression des DB Subnet Groups pour RDS..."
  for subnet_group in $(aws rds describe-db-subnet-groups --region "$region" --query "DBSubnetGroups[*].DBSubnetGroupName" --output text); do
    echo "   ➤ Suppression du DB Subnet Group: $subnet_group"
    aws rds delete-db-subnet-group --db-subnet-group-name "$subnet_group" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du DB Subnet Group $subnet_group."
    }
  done

  # Suppression des clusters ElastiCache (Redis)
  echo "🔹 Suppression des clusters ElastiCache..."
  for cache in $(aws elasticache describe-cache-clusters --region "$region" --query "CacheClusters[*].CacheClusterId" --output text); do
    echo "   ➤ Suppression du cluster ElastiCache: $cache"
    aws elasticache delete-cache-cluster --cache-cluster-id "$cache" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du cluster ElastiCache $cache."
    }
    # Attendre que le cluster soit supprimé
    echo "   ⏳ Attente de la suppression du cluster ElastiCache $cache..."
    aws elasticache wait cache-cluster-deleted --cache-cluster-id "$cache" --region "$region" || true
  done

  # Suppression des groupes de sous-réseaux ElastiCache (nécessaire avant de supprimer les sous-réseaux)
  echo "🔹 Suppression des groupes de sous-réseaux ElastiCache..."
  for subnet_group in $(aws elasticache describe-cache-subnet-groups --region "$region" --query "CacheSubnetGroups[*].CacheSubnetGroupName" --output text); do
    echo "   ➤ Suppression du groupe de sous-réseaux ElastiCache: $subnet_group"
    aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$subnet_group" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du groupe de sous-réseaux ElastiCache $subnet_group."
    }
  done

  # Libération des adresses IP élastiques (avant les NAT Gateways)
  echo "🔹 Libération des adresses IP élastiques..."
  for alloc in $(aws ec2 describe-addresses --region "$region" --query "Addresses[*].AllocationId" --output text); do
    echo "   ➤ Libération de l’EIP: $alloc"
    aws ec2 release-address --allocation-id "$alloc" --region "$region" || {
      echo "   ⚠️ Échec de la libération de l’EIP $alloc."
    }
  done

  # Suppression des NAT Gateways
  echo "🔹 Suppression des NAT Gateways..."
  for nat in $(aws ec2 describe-nat-gateways --region "$region" --query "NatGateways[*].NatGatewayId" --output text); do
    echo "   ➤ Suppression du NAT Gateway: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du NAT Gateway $nat."
    }
    # Attendre que le NAT Gateway soit supprimé
    echo "   ⏳ Attente de la suppression du NAT Gateway $nat..."
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat" --region "$region" || true
  done

  # Suppression des Security Groups (sauf ceux par défaut)
  echo "🔹 Suppression des Security Groups..."
  for sg in $(aws ec2 describe-security-groups --region "$region" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    echo "   ➤ Suppression du Security Group: $sg"
    # Supprimer les règles d'entrée et de sortie pour éviter les dépendances
    aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$region" --protocol all --port all --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 revoke-security-group-egress --group-id "$sg" --region "$region" --protocol all --port all --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 delete-security-group --group-id "$sg" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du Security Group $sg. Vérifiez les dépendances."
    }
  done

  # Suppression des VPCs (après avoir supprimé les dépendances)
  echo "🔹 Suppression des VPCs..."
  for vpc in $(aws ec2 describe-vpcs --region "$region" --query "Vpcs[*].VpcId" --output text); do
    # Ignorer le VPC par défaut
    is_default=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --region "$region" --query "Vpcs[0].IsDefault" --output text)
    if [ "$is_default" == "false" ]; then
      echo "   ➤ Suppression du VPC: $vpc"
      # Supprimer les dépendances du VPC (sous-réseaux, tables de routage, gateways Internet)
      for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --region "$region" --query "Subnets[*].SubnetId" --output text); do
        echo "      ➤ Suppression du sous-réseau: $subnet"
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$region" || true
      done
      for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --region "$region" --query "RouteTables[*].RouteTableId" --output text); do
        echo "      ➤ Suppression de la table de routage: $rt"
        aws ec2 delete-route-table --route-table-id "$rt" --region "$region" || true
      done
      for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --region "$region" --query "InternetGateways[*].InternetGatewayId" --output text); do
        echo "      ➤ Détachement et suppression de l’Internet Gateway: $igw"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$region" || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$region" || true
      done
      # Supprimer le VPC
      aws ec2 delete-vpc --vpc-id "$vpc" --region "$region" || {
        echo "   ⚠️ Échec de la suppression du VPC $vpc. Vérifiez les dépendances restantes."
      }
    fi
  done

  echo "✅ Région $region traitée."
done

echo "🚀 Nettoyage terminé !"