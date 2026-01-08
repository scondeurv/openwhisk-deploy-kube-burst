#!/bin/bash
echo "Iniciando redirección de puerto 31001 para OpenWhisk..."
kubectl port-forward -n openwhisk svc/owdev-nginx 31001:443 --address 0.0.0.0
