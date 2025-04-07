#!/bin/bash

set -euo pipefail

################################################################
# Ce script nettoie les ressources AWS *uniquement* dans us-east-1
# et us-east-2. Si tu veux cibler une seule région, remplace la
# variable `regions` par "us-east-1" ou "us-east-2" uniquement.
################################################################

regions="us-east-1 us-east-2"

echo "🔍 Début du nettoyage des ressources AWS (régions us-east) ..."

# Vérifier que l'utilisateur a les permissions nécessaires
echo "🔐 Vérification des permissions AWS..."
aws sts get-caller-identity > /dev/null || {
  echo "❌ Erreur : Impossible de vérifier les permissions AWS. Assurez-vous que vos credentials sont configurées et que vous avez les permissions nécessaires."
  exit 1
}

# Supprimer les buckets S3 (global, pas besoin de boucle sur les régions)
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

# Désactiver la protection contre la suppression pour toutes les instances RDS
for rdsinst in $(aws rds describe-db-instances --region "$region" --query "DBInstances[*].DBInstanceIdentifier" --output text 2>/dev/null); do
    echo "   ➤ Désactivation de la protection pour l’instance RDS: $rdsinst"
    aws rds modify-db-instance \
        --db-instance-identifier "$rdsinst" \
        --no-deletion-protection \
        --apply-immediately \
        --region "$region" || true
done

# Boucle sur us-east-1 et us-east-2
for region in $regions; do
  echo ""
  echo "🌍 Région en cours: $region"

  # Suppression des clusters EKS
  echo "🔹 Suppression des clusters EKS..."
  for cluster in $(aws eks list-clusters --region "$region" --query "clusters[]" --output text); do
    echo "   ➤ Suppression du cluster EKS: $cluster"
    eksctl delete cluster --name "$cluster" --region "$region" --wait || {
      echo "   ⚠️ Échec de la suppression du cluster EKS $cluster via eksctl. Tentative de suppression manuelle des stacks CloudFormation..."
    }
  done

  # Suppression des stacks CloudFormation résiduelles pour EKS
  echo "🔹 Suppression des stacks CloudFormation EKS..."
  for stack in $(aws cloudformation describe-stacks --region "$region" --query "Stacks[?starts_with(StackName, 'eksctl-')].StackName" --output text); do
    echo "   ➤ Suppression de la stack CloudFormation: $stack"
    aws cloudformation delete-stack --stack-name "$stack" --region "$region" || {
      echo "   ⚠️ Échec de la suppression de la stack $stack."
    }
    echo "   ⏳ Attente de la suppression de la stack $stack..."
    aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$region" || {
      echo "   ⚠️ La stack $stack n'a pas pu être supprimée complètement."
    }
  done

  # DocumentDB : Instances, Clusters, Subnet Groups
  echo "🔹 Suppression des instances DocumentDB..."
  for dbinst in $(aws docdb describe-db-instances --region "$region" --query "DBInstances[*].DBInstanceIdentifier" --output text 2>/dev/null); do
    echo "   ➤ Suppression de l’instance DocumentDB: $dbinst"
    aws docdb delete-db-instance --db-instance-identifier "$dbinst" --region "$region" || {
      echo "   ⚠️ Échec de la suppression de l’instance DocumentDB $dbinst."
    }
    echo "   ⏳ Attente de la suppression de l’instance DocumentDB $dbinst..."
    aws docdb wait db-instance-deleted --db-instance-identifier "$dbinst" --region "$region" || true
  done

  echo "🔹 Suppression des clusters DocumentDB..."
  for cluster in $(aws docdb describe-db-clusters --region "$region" --query "DBClusters[*].DBClusterIdentifier" --output text 2>/dev/null); do
    echo "   ➤ Suppression du cluster DocumentDB: $cluster"
    aws docdb delete-db-cluster --db-cluster-identifier "$cluster" --region "$region" --skip-final-snapshot || {
      echo "   ⚠️ Échec de la suppression du cluster DocumentDB $cluster."
    }
    echo "   ⏳ Attente de la suppression du cluster DocumentDB $cluster..."
    aws docdb wait db-cluster-deleted --db-cluster-identifier "$cluster" --region "$region" || true
  done

  echo "🔹 Suppression des DB Subnet Groups (DocumentDB)..."
  for subnet_group in $(aws docdb describe-db-subnet-groups --region "$region" --query "DBSubnetGroups[*].DBSubnetGroupName" --output text 2>/dev/null); do
    echo "   ➤ Suppression du DB Subnet Group: $subnet_group"
    aws docdb delete-db-subnet-group --db-subnet-group-name "$subnet_group" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du DB Subnet Group $subnet_group."
    }
  done

  # RDS : Instances, Subnet Groups
  echo "🔹 Suppression des instances RDS..."
  for rdsinst in $(aws rds describe-db-instances --region "$region" --query "DBInstances[*].DBInstanceIdentifier" --output text 2>/dev/null); do
    echo "   ➤ Suppression de l’instance RDS: $rdsinst"
    aws rds delete-db-instance --db-instance-identifier "$rdsinst" --region "$region" --skip-final-snapshot || {
      echo "   ⚠️ Échec de la suppression de l’instance RDS $rdsinst."
    }
    echo "   ⏳ Attente de la suppression de l’instance RDS $rdsinst..."
    aws rds wait db-instance-deleted --db-instance-identifier "$rdsinst" --region "$region" || true
  done

  echo "🔹 Suppression des DB Subnet Groups (RDS)..."
  for subnet_group in $(aws rds describe-db-subnet-groups --region "$region" --query "DBSubnetGroups[*].DBSubnetGroupName" --output text 2>/dev/null); do
    echo "   ➤ Suppression du DB Subnet Group: $subnet_group"
    aws rds delete-db-subnet-group --db-subnet-group-name "$subnet_group" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du DB Subnet Group $subnet_group."
    }
  done

  # ElastiCache : clusters, subnet groups
  echo "🔹 Suppression des clusters ElastiCache..."
  for cache in $(aws elasticache describe-cache-clusters --region "$region" --query "CacheClusters[*].CacheClusterId" --output text 2>/dev/null); do
    echo "   ➤ Suppression du cluster ElastiCache: $cache"
    aws elasticache delete-cache-cluster --cache-cluster-id "$cache" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du cluster ElastiCache $cache."
    }
    echo "   ⏳ Attente de la suppression du cluster ElastiCache $cache..."
    aws elasticache wait cache-cluster-deleted --cache-cluster-id "$cache" --region "$region" || true
  done

  echo "🔹 Suppression des groupes de sous-réseaux ElastiCache..."
  for ecsng in $(aws elasticache describe-cache-subnet-groups --region "$region" --query "CacheSubnetGroups[*].CacheSubnetGroupName" --output text 2>/dev/null); do
    echo "   ➤ Suppression du groupe de sous-réseaux ElastiCache: $ecsng"
    aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$ecsng" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du groupe de sous-réseaux ElastiCache $ecsng."
    }
  done

  # EIP
  echo "🔹 Libération des adresses IP élastiques (EIPs)..."
  for alloc in $(aws ec2 describe-addresses --region "$region" --query "Addresses[*].AllocationId" --output text 2>/dev/null); do
    echo "   ➤ Libération de l’EIP: $alloc"
    aws ec2 release-address --allocation-id "$alloc" --region "$region" || {
      echo "   ⚠️ Échec de la libération de l’EIP $alloc."
    }
  done

  # NAT Gateways
  echo "🔹 Suppression des NAT Gateways..."
  for nat in $(aws ec2 describe-nat-gateways --region "$region" --query "NatGateways[*].NatGatewayId" --output text 2>/dev/null); do
    echo "   ➤ Suppression du NAT Gateway: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du NAT Gateway $nat."
    }
    echo "   ⏳ Attente de la suppression du NAT Gateway $nat..."
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat" --region "$region" || true
  done

  # Security Groups
  echo "🔹 Suppression des Security Groups (non 'default')..."
  for sg in $(aws ec2 describe-security-groups --region "$region" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
    echo "   ➤ Suppression du Security Group: $sg"
    # Révoquer les règles
    aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$region" --protocol all --port all --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 revoke-security-group-egress --group-id "$sg" --region "$region" --protocol all --port all --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 delete-security-group --group-id "$sg" --region "$region" || {
      echo "   ⚠️ Échec de la suppression du Security Group $sg."
    }
  done

  # VPC
  echo "🔹 Suppression des VPCs (non 'default')..."
  for vpc in $(aws ec2 describe-vpcs --region "$region" --query "Vpcs[*].VpcId" --output text 2>/dev/null); do
    is_default=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --region "$region" --query "Vpcs[0].IsDefault" --output text 2>/dev/null || echo "false")
    if [ "$is_default" == "false" ]; then
      echo "   ➤ Suppression du VPC: $vpc"
      # Sous-réseaux
      for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --region "$region" --query "Subnets[*].SubnetId" --output text 2>/dev/null); do
        echo "      ➤ Suppression du sous-réseau: $subnet"
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$region" || true
      done
      # Tables de routage
      for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --region "$region" --query "RouteTables[*].RouteTableId" --output text 2>/dev/null); do
        echo "      ➤ Suppression de la table de routage: $rt"
        aws ec2 delete-route-table --route-table-id "$rt" --region "$region" || true
      done
      # Internet Gateways
      for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --region "$region" --query "InternetGateways[*].InternetGatewayId" --output text 2>/dev/null); do
        echo "      ➤ Détachement et suppression de l’Internet Gateway: $igw"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$region" || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$region" || true
      done
      # Supprimer le VPC
      aws ec2 delete-vpc --vpc-id "$vpc" --region "$region" || {
        echo "   ⚠️ Échec de la suppression du VPC $vpc."
      }
    fi
  done

  echo "✅ Région $region traitée."
done

echo "🔹 Suppression des snapshots RDS (manuels) ..."

# Lister tous les snapshots "manual"
snapshots=$(aws rds describe-db-snapshots \
  --region us-east-1 \
  --snapshot-type manual \
  --query "DBSnapshots[].DBSnapshotIdentifier" \
  --output text 2>/dev/null)

for snap in $snapshots; do
  echo "   ➤ Suppression du snapshot RDS: $snap"
  aws rds delete-db-snapshot \
    --db-snapshot-identifier "$snap" \
    --region us-east-1 || {
      echo "   ⚠️ Échec de la suppression du snapshot $snap."
    }
done


echo "🚀 Nettoyage terminé !"
