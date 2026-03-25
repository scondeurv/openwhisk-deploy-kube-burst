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

# Politica de benchmarking justa:
# - cada worker de usuario dispone de 1 CPU dedicada
# - el clúster reserva CPU extra para controller, invoker, nginx y servicios base
WORKER_COUNT=${OW_WORKER_COUNT:-4}
CPU_PER_WORKER=${OW_CPU_PER_WORKER:-1}
SYSTEM_RESERVED_CPUS=${OW_SYSTEM_RESERVED_CPUS:-6}
MEMORY_PER_WORKER_MB=${OW_MEMORY_PER_WORKER_MB:-4096}
SYSTEM_RESERVED_MEM_MB=${OW_SYSTEM_RESERVED_MEM_MB:-8192}

# Detectar recursos del sistema
TOTAL_CPUS=$(nproc)
# free -m devuelve en Megabytes. awk toma la segunda columna de la línea que empieza por Mem:
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')

# Dimensionar Minikube a partir del presupuesto de workers
TARGET_CPUS=$((WORKER_COUNT * CPU_PER_WORKER + SYSTEM_RESERVED_CPUS))
TARGET_MEM=$((WORKER_COUNT * MEMORY_PER_WORKER_MB + SYSTEM_RESERVED_MEM_MB))

# Dejar siempre algo de margen al host
MAX_CPUS=$((TOTAL_CPUS - 1))
if [ "$MAX_CPUS" -lt 2 ]; then MAX_CPUS=$TOTAL_CPUS; fi
MAX_MEM=$((TOTAL_MEM * 9 / 10))

CPUS=$TARGET_CPUS
MEM=$TARGET_MEM

if [ "$CPUS" -gt "$MAX_CPUS" ]; then CPUS=$MAX_CPUS; fi
if [ "$MEM" -gt "$MAX_MEM" ]; then MEM=$MAX_MEM; fi

# Asegurar mínimos razonables (por si acaso)
if [ "$CPUS" -lt 2 ]; then CPUS=2; fi
if [ "$MEM" -lt 2048 ]; then MEM=2048; fi

echo "⚙️  Politica de workers: ${WORKER_COUNT} workers x ${CPU_PER_WORKER} CPU = $((WORKER_COUNT * CPU_PER_WORKER)) CPUs de usuario"
echo "⚙️  Reserva de sistema: ${SYSTEM_RESERVED_CPUS} CPUs, ${SYSTEM_RESERVED_MEM_MB}MB RAM"
echo "⚙️  Configurando Minikube con límites: CPUs=$CPUS, RAM=${MEM}MB"

minikube start --driver docker --cpus $CPUS --memory ${MEM}m --ports 31001:31001,5672:30672,15672:31672,6379:31379,9000:30000,9001:30001

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
