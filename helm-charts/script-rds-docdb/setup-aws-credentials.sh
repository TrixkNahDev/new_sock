#!/bin/bash

# Variables
SECRET_NAME="aws-credentials"
AWS_ACCESS_KEY_ID="QUtJQVczVlJHNkZOV1NXSUpSTEg="
AWS_SECRET_ACCESS_KEY="emZnb1lxNHJ2a0ZiQlVVODB6U2J6UStSdUNNb2l2MlBTMEEwbVBWeg=="
AWS_DEFAULT_REGION="us-east-1"

# Créer le Secret dans Kubernetes avec les identifiants AWS
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
type: Opaque
data:
  AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY
  AWS_DEFAULT_REGION: $(echo -n $AWS_DEFAULT_REGION | base64)
EOF

echo "AWS credentials secret created."
