#!/bin/bash

# Este script arranca Minikube mapeando el puerto 31001 de forma permanente
# para que OpenWhisk sea siempre accesible en https://localhost:31001

echo "🚀 Arrancando Minikube con mapeo de puertos..."
minikube start --ports 31001:31001

echo "🔄 Asegurando que la configuración de OpenWhisk esté aplicada..."
helm upgrade owdev ./helm/openwhisk -n openwhisk -f mycluster.yaml

echo "✅ OpenWhisk debería estar disponible en: https://localhost:31001"
echo "Recuerda que si el clúster es nuevo, los pods pueden tardar un poco en estar 'Running'."
