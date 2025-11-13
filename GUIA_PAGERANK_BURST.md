# Guía Completa: PageRank Distribuido con OpenWhisk + Burst Communication (macOS)

Esta guía te permite configurar y ejecutar PageRank distribuido usando OpenWhisk con comunicación entre workers vía Redis Streams en macOS con Docker Desktop.

---

## 📋 Pre-requisitos

- **Docker Desktop para macOS** con Kubernetes habilitado
- **Helm 3** instalado (`brew install helm`)
- **uv** instalado (gestor de paquetes Python moderno: `brew install uv`)
- **kubectl** configurado (viene con Docker Desktop)
- **wsk CLI** instalado para OpenWhisk
- **Redis** corriendo (via Kubernetes o Docker)

---

## 1. Preparar Repositorios

```bash
cd ~/src

# Clonar o verificar que tienes:
# - openwhisk-deploy-kube-burst/
# - burst-validation/
```

---

## 2. Instalar Infraestructura Externa

### 2.1 Redis (para comunicación entre workers)

**Opción A: Redis en Kubernetes (Recomendado para macOS)**

Redis ya debería estar corriendo en tu cluster. Verifica:

```bash
kubectl get svc | grep redis
# Debería mostrar algo como: redis-service
```

**Opción B: Redis en Docker**

```bash
docker run -d \
  --name redis \
  -p 6379:6379 \
  redis:latest
```

**Verificar desde macOS:**
```bash
# Instalar redis-cli si no lo tienes
brew install redis

# Probar conexión (ajusta IP según tu configuración)
redis-cli -h 192.168.1.220 ping
# Debe retornar: PONG
```

### 2.2 MinIO (almacenamiento S3 compatible)

MinIO debería estar desplegado en Kubernetes con NodePort. Verifica:

```bash
kubectl get svc | grep minio
# Debería mostrar:
# minio-nodeport   NodePort    ...   9000:30000/TCP,9001:30001/TCP
# minio-service    ClusterIP   ...   9000/TCP,9001/TCP
```

**Acceder a MinIO desde macOS:**
- Console UI: `http://192.168.1.220:30001` (puerto NodePort 30001)
- API S3: `http://192.168.1.220:30000` (puerto NodePort 30000)
- Usuario: `minioadmin`, Password: `minioadmin`

**Si necesitas desplegarlo:**

```bash
kubectl apply -f minio.yaml
```

### 2.3 RabbitMQ (para mensajería de OpenWhisk)

RabbitMQ puede correr en Docker o Kubernetes. Para Docker:

```bash
docker run -d \
  --name rabbitmq \
  -p 5672:5672 \
  -p 15672:15672 \
  rabbitmq:3-management
```

**Verificar:**
```bash
# Acceder a http://192.168.1.220:15672
# Usuario: guest, Password: guest
```

---

## 3. Configurar OpenWhisk

### 3.1 Revisar configuración en `mycluster.yaml`

Tu archivo `mycluster.yaml` debe tener esta configuración para macOS:

```yaml
whisk:
  middleware:
    rabbitmq: "amqp://guest:guest@192.168.1.220:5672"
    redisList: "redis://192.168.1.220:6379"
    redisStream: "redis://192.168.1.220:6379"  # ← Clave para burst
  ingress:
     type: NodePort
     apiHostName: 192.168.1.220
     apiHostPort: 31001
     useInternally: false
  versions:
    openwhisk:
      gitTag: "72bb2a1"

controller:
  imageName: "manriurv/controller"
  imageTag: "classic"  # ← Imagen custom con soporte burst

invoker:
  imageName: "manriurv/invoker"
  imageTag: "classic"  # ← Imagen custom con soporte burst
  containerFactory:
    impl: "docker" 

nginx:
  httpsNodePort: 31001

zookeeper:
  imageTag: "3.5"
  port: 2181
  readinessProbe:
    enabled: false  # ← Deshabilitado por incompatibilidad con comando "ruok"

k8s:
  persistence:
    enabled: false
```

**⚠️ IMPORTANTE para macOS:**
- Usa tu IP local de macOS (obtén con `ifconfig | grep "inet " | grep -v 127.0.0.1`)
- La IP `192.168.1.220` es un ejemplo, ajusta según tu red
- MinIO debe usar el puerto NodePort `30000` (no 9000 directamente)

### 3.2 Desplegar OpenWhisk en Kubernetes

```bash
cd ~/src/openwhisk-deploy-kube-burst

# Crear namespace
kubectl create namespace openwhisk

# Etiquetar nodos para invokers
kubectl label nodes --all openwhisk-role=invoker

# Instalar con Helm
helm install owdev ./helm/openwhisk \
  -n openwhisk \
  -f mycluster.yaml

# Monitorear despliegue (puede tardar 5-10 minutos)
kubectl get pods -n openwhisk -w
```

**⚠️ Parches necesarios para Zookeeper en macOS:**

Zookeeper 3.5+ tiene el comando `ruok` deshabilitado por defecto, lo que causa que los readiness probes fallen. Después del despliegue inicial, aplica estos parches:

```bash
# 1. Eliminar readiness probe de Zookeeper
kubectl patch statefulset -n openwhisk owdev-zookeeper --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"}]'

# 2. Eliminar init containers que esperan por Zookeeper
kubectl patch statefulset -n openwhisk owdev-kafka --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]'

kubectl patch statefulset -n openwhisk owdev-controller --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]'

# 3. Eliminar init containers de deployments
kubectl get deployments -n openwhisk -o name | \
  xargs -I {} kubectl patch -n openwhisk {} --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]'

# 4. Eliminar init containers del invoker (DaemonSet)
kubectl patch daemonset -n openwhisk owdev-invoker --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]'

# 5. Esperar a que todos los pods estén Running
sleep 60 && kubectl get pods -n openwhisk
```

**Pods esperados:**

```plaintext
NAME                              READY   STATUS      RESTARTS   AGE
owdev-alarmprovider-xxx           1/1     Running     0          5m
owdev-controller-0                1/1     Running     0          5m
owdev-invoker-xxx                 1/1     Running     0          5m
owdev-kafka-0                     1/1     Running     0          5m
owdev-nginx-xxx                   1/1     Running     0          5m
owdev-zookeeper-0                 1/1     Running     0          5m
owdev-install-packages-xxx        0/1     Error       0          5m  # ← Error esperado (paquetes API Gateway)
```

**Nota:** El pod `install-packages` puede fallar instalando paquetes de API Gateway, pero esto no afecta la funcionalidad de PageRank.

---

## 4. Compilar Acción de PageRank

### 4.1 Estructura correcta para OpenWhisk Rust Runtime

El runtime de OpenWhisk para Rust **compila el código fuente** dentro del contenedor, no ejecuta binarios precompilados. Por lo tanto, el ZIP debe contener el código fuente Rust.

### 4.2 Navegar al código

```bash
cd ~/src/burst-validation/pagerank/ow-pr
```

### 4.3 Configurar Cargo.toml

El `Cargo.toml` debe tener esta configuración especial:

```toml
[dependencies]
burst-communication-middleware = { path = "/usr/src/burst-communication-middleware", features = ["redis"] }
```

**⚠️ IMPORTANTE:** 
- El path debe ser `/usr/src/burst-communication-middleware` (ruta absoluta dentro del contenedor)
- El runtime de OpenWhisk copia automáticamente las dependencias locales a `/usr/src/`
- NO incluyas `burst-communication-middleware/` en el ZIP

### 4.4 Crear ZIP con código fuente

```bash
# Desde el directorio ow-pr/
cd ~/src/burst-validation/pagerank/ow-pr

# Crear ZIP SOLO con Cargo.toml, Cargo.lock y src/
zip -r ../pagerank.zip Cargo.toml Cargo.lock src/

# Verificar contenido (debe ser ~95KB, no 26MB)
ls -lh ../pagerank.zip
unzip -l ../pagerank.zip | head -20
```

**Estructura esperada del ZIP:**

```plaintext
Archive: pagerank.zip
  Cargo.toml          (configuración del proyecto)
  Cargo.lock          (dependencias bloqueadas)
  src/lib.rs          (lógica de PageRank)
  src/testing.rs      (entry point del binario)
```

**NO incluir:**
- ❌ `target/` (binarios compilados)
- ❌ `burst-communication-middleware/` (el runtime lo maneja)
- ❌ `.git/` (control de versiones)
- ❌ Archivos `.DS_Store` (macOS)

---

## 5. Configurar Entorno Python con uv

### 5.1 Crear entorno virtual

```bash
cd ~/src/burst-validation

# Crear entorno con uv
uv venv

# Activar entorno
source .venv/bin/activate
```

### 5.2 Instalar dependencias

```bash
# Instalar paquetes desde requirements.txt
uv pip install -r requirements.txt
```

### 5.3 Verificar instalación

```bash
uv run python -c "from ow_client.openwhisk_executor import OpenwhiskExecutor; print('✓ OK')"
```

---

## 6. Preparar Datos en MinIO

### 6.1 Instalar MinIO Client

```bash
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/
```

### 6.2 Configurar conexión

```bash
mc alias set myminio http://192.168.1.213:9000 minioadmin minioadmin
```

### 6.3 Crear bucket

```bash
mc mb myminio/pagerank-data
```

### 6.4 Generar y subir datos de prueba

```bash
cd ~/src/burst-validation/pagerank

# Ver opciones disponibles
uv run python generate_payload.py --help

# Generar datos de grafo particionado
# (ajusta parámetros según tu caso de uso)
# ⚠️ IMPORTANTE: Usa puerto NodePort 30000 para MinIO, no 9000
uv run python generate_payload.py \
  --partitions 4 \
  --num_nodes 5 \
  --bucket pagerank-data \
  --key 1 \
  --endpoint http://192.168.1.220:30000
```

Esto crea archivos en MinIO:

- `pagerank-data/1/part-00000`
- `pagerank-data/1/part-00001`
- `pagerank-data/1/part-00002`
- `pagerank-data/1/part-00003`

---

## 7. Ejecutar PageRank Distribuido

### 7.1 Ejecutar con uv

```bash
cd ~/src/burst-validation/pagerank

# ⚠️ IMPORTANTE: 
# - Ajusta la IP a tu configuración
# - Usa puerto NodePort 30000 para MinIO (no 9000)
# - Asegúrate de que PYTHONPATH esté configurado

PYTHONPATH=/Users/sergio/src/burst-validation:$PYTHONPATH \
uv run python pagerank.py \
  --ow-host 192.168.1.220 \
  --ow-port 31001 \
  --backend redis-stream \
  --partitions 2 \
  --num-nodes 100 \
  --bucket pagerank-data \
  --key 1 \
  --pr-endpoint http://192.168.1.220:30000
```

**Nota sobre la imagen Docker:**

El script `pagerank.py` usa automáticamente la imagen `burstcomputing/runtime-rust-burst:latest` que incluye el runtime de Rust con soporte para burst communication.

### 7.2 Descripción de parámetros

| Parámetro | Descripción | Valor recomendado macOS |
|-----------|-------------|-------------------------|
| `--ow-host` | IP donde corre OpenWhisk | Tu IP local (ej: `192.168.1.220`) |
| `--ow-port` | Puerto de OpenWhisk API | `31001` |
| `--backend` | Middleware de comunicación | `redis-stream` |
| `--partitions` | Particiones del grafo | `2` o `4` |
| `--num-nodes` | Número total de nodos en el grafo | `100` (ajustar según datos) |
| `--bucket` | Bucket en MinIO | `pagerank-data` |
| `--key` | Prefijo de los archivos | `1` |
| `--pr-endpoint` | URL de MinIO | `http://192.168.1.220:30000` ⚠️ NodePort |

### 7.3 Salida esperada

El script mostrará:

```plaintext
2025-11-13 11:28:44 - INFO - OpenwhiskExecutor initialized
2025-11-13 11:29:12 - INFO - Function pagerank created in Openwhisk successfully
2025-11-13 11:29:12 - INFO - Burst pagerank invoked successfully. Actions: ['a70cb37f129a49da8cb37f129a49da2e']
2025-11-13 11:31:08 - INFO - Function a70cb37f129a49da8cb37f129a49da2e finished
2025-11-13 11:31:08 - INFO - [a70cb37f129a49da8cb37f129a49da2e finished]: [
  {
    "bucket": "pagerank-data",
    "key": "1/part-00000",
    "timestamps": [
      {"key": "worker_start", "value": "1763029867568"},
      {"key": "get_input", "value": "1763029867773"},
      {"key": "iter_0_start", "value": "1763029867774"},
      {"key": "iter_0_broadcast_weights", "value": "1763029867779"},
      {"key": "iter_0_reduce", "value": "1763029867781"},
      ...
      {"key": "worker_end", "value": "1763029867783"}
    ]
  }
]
```

Los resultados se guardan en `pagerank-burst.json`.

---

## 8. Analizar Resultados

### 8.1 Estructura de timestamps

Cada worker genera estos eventos:

```
worker_start              ← Inicio del worker
get_input                 ← Carga datos desde S3
calc_outlinks             ← Calcula enlaces salientes
iter_0_start              ← Inicio iteración 0
iter_0_broadcast_weights  ← Envía pesos a otros workers
iter_0_calc_sums          ← Calcula sumas locales
iter_0_reduce             ← Recibe datos de otros workers
iter_0_calc_err           ← Calcula error local
iter_0_broadcast_err      ← Envía error a todos
iter_0_end                ← Fin iteración 0
...                       ← Más iteraciones
worker_end                ← Fin del worker
```

### 8.2 Métricas de rendimiento

De tu ejecución real:
- **4 workers** ejecutándose en paralelo
- **24 iteraciones** completadas
- **Tiempo total:** ~39ms (1761432274155 → 1761432274194)
- **Tiempo por iteración:** ~1-2ms
- **Comunicación:** Redis Streams funcionando correctamente

---

## 9. Monitoreo y Debugging

### 9.1 Ver pods de OpenWhisk

```bash
# Listar todos los pods
kubectl get pods -n openwhisk

# Ver estado detallado
kubectl describe pod -n openwhisk owdev-invoker-0
```

### 9.2 Ver logs en tiempo real

```bash
# Logs del invoker (donde se ejecutan las acciones)
kubectl logs -n openwhisk owdev-invoker-0 -f

# Logs del controller
kubectl logs -n openwhisk owdev-controller-0 -f

# Logs de nginx (gateway)
kubectl logs -n openwhisk <nginx-pod-name> -f
```

### 9.3 Verificar Redis Streams

```bash
# Conectar a Redis
redis-cli -h 192.168.1.213

# Listar todos los streams
KEYS "*stream*"

# Ejemplo de output:
# broadcast_stream:54b901e0-cee3-423d-8545-2c70907c775d:g0
# broadcast_stream:54b901e0-cee3-423d-8545-2c70907c775d:g1
# direct_stream:54b901e0-cee3-423d-8545-2c70907c775d:s0-d1

# Ver contenido de un stream
XRANGE broadcast_stream:54b901e0-cee3-423d-8545-2c70907c775d:g0 - +

# Ver longitud de un stream
XLEN broadcast_stream:54b901e0-cee3-423d-8545-2c70907c775d:g0

# Limpiar streams antiguos (si es necesario)
FLUSHDB
```

### 9.4 Verificar datos en MinIO

```bash
# Listar archivos en el bucket
mc ls myminio/pagerank-data/1/

# Descargar un archivo para inspección
mc cp myminio/pagerank-data/1/part-00000 /tmp/
cat /tmp/part-00000
```

---

## 10. Estructura del Proyecto

```
~/src/
├── openwhisk-deploy-kube-burst/
│   ├── mycluster.yaml              ← Configuración OpenWhisk
│   ├── helm/openwhisk/             ← Helm charts
│   └── GUIA_PAGERANK_BURST.md      ← Esta guía
│
└── burst-validation/
    ├── requirements.txt            ← Dependencias Python
    ├── .venv/                      ← Entorno virtual (uv)
    │
    ├── ow_client/                  ← Cliente Python para OpenWhisk
    │   ├── __init__.py
    │   ├── openwhisk_executor.py   ← Ejecutor de acciones burst
    │   ├── parser.py               ← Parseo de argumentos
    │   ├── time_helper.py          ← Utilidades de tiempo
    │   └── utils.py
    │
    ├── pagerank/
    │   ├── pagerank.py             ← Script principal de ejecución
    │   ├── pagerank_utils.py       ← Utilidades para PageRank
    │   ├── generate_payload.py     ← Generador de datos de grafo
    │   ├── pagerank.zip            ← Acción compilada para OpenWhisk
    │   │
    │   ├── ow-pr/                  ← Código Rust
    │   │   ├── Cargo.toml
    │   │   ├── src/
    │   │   │   └── lib.rs
    │   │   ├── target/release/ow-pr
    │   │   └── action/
    │   │       ├── exec/exec
    │   │       └── compile.py
    │   │
    │   └── burst-communication-middleware/  ← Librería de comunicación
    │       ├── Cargo.toml
    │       └── src/
    │           ├── lib.rs
    │           ├── middleware.rs
    │           ├── actor.rs
    │           └── backends/
    │
    └── burst-communication-middleware/      ← Submódulo Git compartido
        └── ...
```

---

## 11. Comandos Útiles con uv

### Gestión de entorno

```bash
# Crear entorno virtual
uv venv

# Activar entorno
source .venv/bin/activate

# Desactivar entorno
deactivate
```

### Gestión de paquetes

```bash
# Instalar dependencias
uv pip install -r requirements.txt

# Instalar paquete específico
uv pip install <paquete>

# Actualizar paquete
uv pip install --upgrade <paquete>

# Listar paquetes instalados
uv pip list

# Generar requirements.txt
uv pip freeze > requirements.txt
```

### Ejecutar scripts

```bash
# Ejecutar sin activar venv
uv run python script.py

# Ejecutar con argumentos
uv run python pagerank.py --help
```

---

## 12. Troubleshooting

### Problema: Pods de OpenWhisk no inician

```bash
# Ver estado detallado
kubectl describe pod -n openwhisk <POD_NAME>

# Ver logs
kubectl logs -n openwhisk <POD_NAME>

# Causas comunes:
# - Recursos insuficientes (RAM/CPU)
# - Imágenes no disponibles
# - Problemas de conectividad con Redis/RabbitMQ
```

**Solución:**
```bash
# Verificar recursos del nodo
kubectl top nodes

# Verificar eventos
kubectl get events -n openwhisk --sort-by='.lastTimestamp'
```

### Problema: Workers se quedan esperando en Redis

```bash
# Verificar conectividad desde los pods
kubectl run -it --rm debug --image=redis --restart=Never -- \
  redis-cli -h 192.168.1.213 ping

# Ver streams activos
redis-cli -h 192.168.1.213 KEYS "*stream*"

# Verificar si hay mensajes atascados
redis-cli -h 192.168.1.213 XLEN broadcast_stream:<transaction_id>:g0
```

**Solución:**
```bash
# Limpiar streams antiguos
redis-cli -h 192.168.1.213 FLUSHDB

# Reiniciar la ejecución
```

### Problema: Error de importación en Python

```bash
# Verificar que estás en el venv
which python
# Debe mostrar: /home/sergio/src/burst-validation/.venv/bin/python

# Reinstalar dependencias
uv pip install --force-reinstall -r requirements.txt
```

### Problema: ZIP de acción incorrecto

```bash
# Verificar contenido del ZIP
unzip -l pagerank.zip

# Debe mostrar:
# ow-pr/action/exec/exec
# ow-pr/action/compile.py
```

**Solución:**
```bash
# Recrear ZIP con estructura correcta
cd ~/src/burst-validation/pagerank
rm pagerank.zip
zip -r pagerank.zip ow-pr/action/ ow-pr/action/compile.py
```

### Problema: No se puede conectar a MinIO

```bash
# Verificar que MinIO está corriendo
docker ps | grep minio

# Probar conexión
curl http://192.168.1.213:9000/minio/health/live
# Debe retornar: 200 OK
```

### Problema: Timeout en ejecución

```bash
# Las acciones tienen timeout configurado
# Si tu grafo es muy grande, aumenta el timeout

# Ver timeout actual
kubectl get configmap -n openwhisk owdev-whisk.config -o yaml | grep timeout

# Ajustar en mycluster.yaml y actualizar deployment
helm upgrade owdev ./helm/openwhisk -n openwhisk -f mycluster.yaml
```

---

## 13. Parámetros de Comunicación Burst

### 13.1 Backends disponibles

| Backend | Descripción | Cuándo usar |
|---------|-------------|-------------|
| `RedisStream` | Redis Streams (recomendado) | Alta velocidad, baja latencia |
| `RedisList` | Redis Lists | Compatibilidad legacy |
| `RabbitMQ` | Colas RabbitMQ | Mensajes grandes, persistencia |

### 13.2 Estructura de burst_info

Automáticamente generado por OpenWhisk:

```json
{
  "burst_info": {
    "1e49845e-2736-4c83-abda-4a4f2deffb3a": [0, 0],  // Worker 0
    "69eb7e57-d2b9-4fe1-9f6a-a1350f24fd48": [1, 1],  // Worker 1
    "77a2c7b8-c0a4-4e18-9beb-522b03ce3d52": [3, 3],  // Worker 3
    "ac75c764-71b7-4c7d-91c0-96c9cadaddcc": [2, 2]   // Worker 2
  },
  "invoker_id": "1e49845e-2736-4c83-abda-4a4f2deffb3a",
  "transaction_id": "54b901e0-cee3-423d-8545-2c70907c775d"
}
```

### 13.3 Naming de Redis Streams

```
broadcast_stream:<transaction_id>:g<worker_id>
direct_stream:<transaction_id>:s<source>-d<destination>
```

Ejemplo:
```
broadcast_stream:54b901e0-cee3-423d-8545-2c70907c775d:g0
direct_stream:54b901e0-cee3-423d-8545-2c70907c775d:s1-d0
```

---

## 14. Optimizaciones y Mejores Prácticas

### 14.1 Ajustar número de workers

```bash
# Para grafos pequeños (< 1000 nodos)
--granularity 2 --partitions 2

# Para grafos medianos (1000-10000 nodos)
--granularity 4 --partitions 4

# Para grafos grandes (> 10000 nodos)
--granularity 8 --partitions 8
```

### 14.2 Configurar chunk_size

Para mensajes grandes (> 1MB):

```bash
uv run python pagerank.py \
  ... \
  --chunk_size 1048576  # 1MB chunks
```

### 14.3 Monitorear recursos

```bash
# Ver uso de CPU/RAM de pods
kubectl top pods -n openwhisk

# Ver uso de nodos
kubectl top nodes
```

---

## 15. Limpieza

### 15.1 Eliminar deployment de OpenWhisk

```bash
# Desinstalar Helm release
helm uninstall owdev -n openwhisk

# Eliminar namespace
kubectl delete namespace openwhisk
```

### 15.2 Limpiar datos en MinIO

```bash
# Eliminar bucket completo
mc rb --force myminio/pagerank-data
```

### 15.3 Detener servicios Docker

```bash
# Detener y eliminar contenedores
docker stop redis rabbitmq minio
docker rm redis rabbitmq minio
```

### 15.4 Limpiar Redis

```bash
# Limpiar todos los datos
redis-cli -h 192.168.1.213 FLUSHALL

# O solo los streams
redis-cli -h 192.168.1.213 FLUSHDB
```

---

## 16. Referencias y Recursos

### Diferencias clave para macOS (rama run_local_mac)

Esta configuración está optimizada para macOS con Docker Desktop:

1. **Zookeeper readiness probe:** Deshabilitado en `mycluster.yaml` y con parches manuales post-instalación
2. **MinIO NodePort:** Usar puerto `30000` (no `9000`) desde los pods de OpenWhisk
3. **Cargo.toml path:** Configurado para `/usr/src/burst-communication-middleware` (path absoluto del runtime)
4. **ZIP structure:** Solo incluye `Cargo.toml`, `Cargo.lock`, y `src/` (NO incluye `burst-communication-middleware/`)
5. **Imagen Docker:** `burstcomputing/runtime-rust-burst:latest` (definida en `parser.py`)

### Configuración clave

- **IP de servicios:** Ajustar según tu red local (obtener con `ifconfig`)
- **Redis:** `redis://192.168.1.220:6379` (o servicio interno de K8s)
- **RabbitMQ:** `amqp://guest:guest@192.168.1.220:5672`
- **MinIO API:** `http://192.168.1.220:30000` ⚠️ NodePort, no 9000
- **MinIO Console:** `http://192.168.1.220:30001`
- **OpenWhisk API:** `http://192.168.1.220:31001`

### Imágenes Docker custom

- **Controller:** `manriurv/controller:classic`
- **Invoker:** `manriurv/invoker:classic`

Estas imágenes incluyen soporte para burst communication.

### Repositorios

- **OpenWhisk Deploy Kube:** `~/src/openwhisk-deploy-kube-burst/`
- **Burst Validation:** `~/src/burst-validation/`
- **Middleware:** `~/src/burst-validation/burst-communication-middleware/`

---

## ✅ Checklist de Verificación

Antes de ejecutar PageRank en macOS, verifica:

- [ ] Docker Desktop con Kubernetes habilitado
- [ ] Redis accesible (Kubernetes o Docker)
- [ ] MinIO corriendo con NodePort 30000/30001
- [ ] RabbitMQ corriendo y accesible (si usas Docker: puerto 5672)
- [ ] Todos los pods de OpenWhisk en estado `Running` (excepto install-packages)
- [ ] Parches de Zookeeper aplicados (readiness probes e init containers eliminados)
- [ ] `Cargo.toml` con path `/usr/src/burst-communication-middleware`
- [ ] `pagerank.zip` creado SIN burst-communication-middleware (~95KB)
- [ ] Bucket `pagerank-data` creado en MinIO
- [ ] Datos particionados subidos a MinIO usando puerto NodePort 30000
- [ ] Entorno Python con uv configurado (`uv pip install -r requirements.txt`)
- [ ] IP correcta en comandos (obtener con `ifconfig`)
- [ ] PYTHONPATH configurado al ejecutar scripts Python

---

## 🎯 Resultado Esperado en macOS

Al ejecutar el script correctamente con 2 partitions, deberías ver:

```plaintext
✓ 2 workers ejecutándose en paralelo
✓ Comunicación vía Redis Streams funcionando
✓ 4 iteraciones de PageRank completadas
✓ Tiempo total de ejecución: ~200ms
✓ Timestamps detallados por cada fase (worker_start, iter_X_broadcast, iter_X_reduce, worker_end)
✓ Resultados guardados en pagerank-burst.json
```

---

## 📧 Soporte

Si encuentras problemas:

1. Revisa la sección de **Troubleshooting**
2. Verifica los logs de Kubernetes: `kubectl logs -n openwhisk <pod-name>`
3. Verifica los streams de Redis: `redis-cli KEYS "*stream*"`
4. Asegúrate de que todos los servicios estén corriendo

---

**¡Listo! Tu sistema de PageRank distribuido con burst communication está funcionando.**
