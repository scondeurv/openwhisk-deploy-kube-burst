#!/bin/bash

# Este script arranca Minikube mapeando el puerto 31001 de forma permanente
# para que OpenWhisk sea siempre accesible en https://localhost:31001

echo "🚀 Arrancando Minikube con mapeo de puertos..."
# Mapeo de puertos:
# 31001: OpenWhisk
# 5672: RabbitMQ AMQP
# 15672: RabbitMQ Management
# 6379: Redis (Dragonfly)
# 9000: MinIO API
# 9001: MinIO Console

# Detectar recursos del sistema y usar el 50%
TOTAL_CPUS=$(nproc)
# free -m devuelve en Megabytes. awk toma la segunda columna de la línea que empieza por Mem:
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')

# Calcular la mitad
CPUS=$(($TOTAL_CPUS * 2 / 3))
MEM=$(($TOTAL_MEM * 2 / 3))

# Asegurar mínimos razonables (por si acaso)
if [ "$CPUS" -lt 2 ]; then CPUS=2; fi
if [ "$MEM" -lt 2048 ]; then MEM=2048; fi

echo "⚙️  Configurando Minikube con límites: CPUs=$CPUS, RAM=${MEM}MB"

minikube start --cpus $CPUS --memory ${MEM}m --ports 31001:31001,5672:30672,15672:31672,6379:31379,9000:30000,9001:30001

echo "🏷️  Etiquetando el nodo para que acepte Invokers..."
kubectl label nodes --all openwhisk-role=invoker --overwrite

echo "📦 Desplegando servicios auxiliares (RabbitMQ, MinIO, Redis/Dragonfly)..."

# Esperar a que el ServiceAccount default esté listo
echo "⏳ Esperando a que el sistema esté listo..."
until kubectl get serviceaccount default > /dev/null 2>&1; do sleep 2; done

kubectl apply -f infrastructure.yaml

echo "🏗️ Creando namespace 'openwhisk'..."
kubectl create namespace openwhisk --dry-run=client -o yaml | kubectl apply -f -

echo "🔄 Instalando/Actualizando OpenWhisk..."
helm upgrade --install owdev ./helm/openwhisk -n openwhisk -f mycluster.yaml

echo "✅ OpenWhisk debería estar disponible en: https://localhost:31001"
echo "Recuerda que si el clúster es nuevo, los pods pueden tardar un poco en estar 'Running'."
