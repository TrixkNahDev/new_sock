#!/bin/bash

# Variables
DB_INSTANCE_IDENTIFIER="sockshop-db-instance"
DB_INSTANCE_CLASS="db.t4g.micro"
DB_ENGINE="mysql"
DB_ENGINE_VERSION="8.0"
DB_USERNAME="admin"
DB_NAME="sockshop"
DB_STORAGE="20"
DB_PORT="3306"
REGION="us-east-1"

# Demander le mot de passe en masqué
read -s -p "Entrez le mot de passe admin RDS : " DB_PASSWORD
echo

# Vérifier si l'instance existe déjà
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" &> /dev/null; then
    echo "L'instance RDS '$DB_INSTANCE_IDENTIFIER' existe déjà. Saut de la création."
    exit 0
fi

# Créer l'instance RDS MySQL
aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --engine "$DB_ENGINE" \
    --engine-version "$DB_ENGINE_VERSION" \
    --allocated-storage "$DB_STORAGE" \
    --db-name "$DB_NAME" \
    --master-username "$DB_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --port "$DB_PORT" \
    --backup-retention-period 1 \
    --no-multi-az \
    --storage-type gp3 \
    --publicly-accessible \
    --tags Key=Project,Value=SockShop \
    --no-deletion-protection

echo "L'instance RDS '$DB_INSTANCE_IDENTIFIER' est en cours de création. Cela peut prendre quelques minutes..."
