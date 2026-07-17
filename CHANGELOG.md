# Changelog — app-demo

Bitácora de cambios del repositorio de la aplicación demo del proyecto CI/CD.
Cada entrada incluye descripción, archivos involucrados y comandos ejecutados.

---

## [2026-07-15] — Setup inicial del proyecto CI/CD

### Qué se hizo
Creación del repositorio `app-demo` con la estructura base del proyecto CI/CD.
Se definió una aplicación demo mínima basada en nginx:alpine con un HTML estático,
un Dockerfile para construir la imagen y un Jenkinsfile para el pipeline de CI/CD.

### Archivos creados

#### `index.html`
```html
<!DOCTYPE html>
<html>
<body>
  <h1>CI/CD Demo v1</h1>
</body>
</html>
```

#### `Dockerfile`
```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

#### `Jenkinsfile` (versión inicial)
```groovy
pipeline {
  agent any

  environment {
    IMAGE = "jsantacruzpy/app-demo"
    TAG   = "${env.BUILD_NUMBER}"
  }

  stages {

    stage('Clone') {
      steps {
        checkout scm
      }
    }

    stage('Build') {
      steps {
        sh "docker build -t ${IMAGE}:${TAG} ."
      }
    }

    stage('Push') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'dockerhub-credentials',
          usernameVariable: 'USER',
          passwordVariable: 'PASS'
        )]) {
          sh "docker login -u $USER -p $PASS"
          sh "docker push ${IMAGE}:${TAG}"
        }
      }
    }

    stage('Update GitOps') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'github-credentials',
          usernameVariable: 'USER',
          passwordVariable: 'PASS'
        )]) {
          sh """
            git clone https://$USER:$PASS@github.com/jsantacruzpy/app-demo-gitops
            cd app-demo-gitops
            sed -i 's|image: ${IMAGE}:.*|image: ${IMAGE}:${TAG}|' base/deployment.yaml
            git config user.email "jenkins@lab.local"
            git config user.name "Jenkins"
            git add .
            git commit -m "ci: update image to ${TAG}"
            git push
          """
        }
      }
    }
  }
}
```

### Comandos ejecutados
```bash
mkdir app-demo && cd app-demo
git init
git add .
git commit -m "init"
git remote add origin https://github.com/jsantacruzpy/app-demo
git push -u origin main
```

### Resultado
Repositorio creado y pusheado a GitHub.

---

## [2026-07-15] — Migración a Kaniko para builds en Kubernetes

### Qué se hizo
Jenkins corre como pod dentro de k3s y no tiene acceso al Docker daemon del host.
Se reemplazó el build con Docker clásico por Kaniko, que construye imágenes sin
necesitar daemon. Se agregó un contenedor `alpine/git` separado para las operaciones
de git, ya que Kaniko no tiene git instalado.

### Problema encontrado
```
docker build: not found
# Docker daemon no disponible dentro del pod de Jenkins
```

### Archivos modificados

#### `Jenkinsfile` — migración a Kaniko con pod multi-contenedor
```groovy
pipeline {
  agent {
    kubernetes {
      yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command: ['sleep', '9999']
    volumeMounts:
    - name: dockerhub-secret
      mountPath: /kaniko/.docker
  - name: git
    image: alpine/git
    command: ['sleep', '9999']
  volumes:
  - name: dockerhub-secret
    secret:
      secretName: dockerhub-secret
      items:
      - key: .dockerconfigjson
        path: config.json
"""
    }
  }

  environment {
    IMAGE = "jsantacruzpy/app-demo"
    TAG   = "${env.BUILD_NUMBER}"
  }

  stages {

    stage('Build & Push') {
      steps {
        container('kaniko') {
          sh """
            /kaniko/executor \
              --context=dir://${env.WORKSPACE} \
              --dockerfile=${env.WORKSPACE}/Dockerfile \
              --destination=${IMAGE}:${TAG} \
              --destination=${IMAGE}:latest
          """
        }
      }
    }

    stage('Update GitOps') {
      steps {
        container('git') {
          withCredentials([usernamePassword(
            credentialsId: 'github-credentials',
            usernameVariable: 'USER',
            passwordVariable: 'PASS'
          )]) {
            sh """
              git clone https://\$USER:\$PASS@github.com/jsantacruzpy/app-demo-gitops
              cd app-demo-gitops
              sed -i 's|image: ${IMAGE}:.*|image: ${IMAGE}:${TAG}|' base/deployment.yaml
              git config user.email "jenkins@lab.local"
              git config user.name "Jenkins"
              git add .
              git commit -m "ci: update image to ${TAG}"
              git push
            """
          }
        }
      }
    }
  }
}
```

### Comandos ejecutados en k3s
```bash
# Crear secret de DockerHub con token
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=jsantacruzpy \
  --docker-password=dckr_pat_XXXXXXXXXX \
  --docker-email=tuemail@gmail.com \
  -n jenkins
```

### Resultado
Pipeline corriendo con Kaniko. Build y push exitosos a DockerHub.

---

## [2026-07-15] — Fix: path del workspace de Kaniko

### Qué se hizo
Kaniko no encontraba el `index.html` porque el path del contexto era incorrecto.
Se reemplazó `dir://workspace` por la variable de entorno `${env.WORKSPACE}` que
Jenkins setea automáticamente con el path real del workspace.

### Problema encontrado
```
error building stage: failed to get files used from context:
failed to get fileinfo for /home/jenkins/agent/workspace/APP-DEMO/workspace/index.html:
lstat: no such file or directory
```

### Archivos modificados

#### `Jenkinsfile` — fix del path de contexto
```groovy
// Antes
--context=dir://workspace

// Después
--context=dir://${env.WORKSPACE}
--dockerfile=${env.WORKSPACE}/Dockerfile
```

### Resultado
Kaniko encuentra el Dockerfile y el index.html correctamente.

---

## [2026-07-15] — Fix: git safe.directory en contenedor alpine/git

### Qué se hizo
El contenedor alpine/git no confiaba en el directorio del workspace porque el
owner del directorio no coincidía con el usuario del contenedor. Git 2.35.2+
requiere configurar safe.directory explícitamente para directorios con ownership
diferente.

### Problema encontrado
```
fatal: detected dubious ownership in repository at '/home/jenkins/agent/workspace/APP-DEMO'
To add an exception for this directory, call:
  git config --global --add safe.directory /home/jenkins/agent/workspace/APP-DEMO
```

### Archivos modificados

#### `Jenkinsfile` — agregar safe.directory antes de comandos git
```groovy
stage('Check Changes') {
  steps {
    container('git') {
      script {
        // Fix de permisos de ownership en el workspace montado
        sh "git config --global --add safe.directory ${env.WORKSPACE}"

        // resto del stage...
      }
    }
  }
}
```

### Resultado
Git opera correctamente sobre el workspace montado en el contenedor.

---

## [2026-07-15] — Feature: detección de cambios para evitar builds innecesarios

### Qué se hizo
Se agregó un stage `Check Changes` que compara los archivos modificados entre
el commit actual y el anterior. Si no hubo cambios en archivos relevantes de la
app (Dockerfile, index.html, src/), se omiten los stages de Build y Push.
Esto evita generar nuevas versiones de imagen en DockerHub cuando solo cambia
el Jenkinsfile u otros archivos no relacionados con la app.

### Archivos modificados

#### `Jenkinsfile` — versión completa con detección de cambios
```groovy
pipeline {

  agent {
    kubernetes {
      yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command: ['sleep', '9999']
    volumeMounts:
    - name: dockerhub-secret
      mountPath: /kaniko/.docker
  - name: git
    image: alpine/git
    command: ['sleep', '9999']
  volumes:
  - name: dockerhub-secret
    secret:
      secretName: dockerhub-secret
      items:
      - key: .dockerconfigjson
        path: config.json
"""
    }
  }

  environment {
    IMAGE = "jsantacruzpy/app-demo"
    TAG   = "${env.BUILD_NUMBER}"
  }

  stages {

    stage('Check Changes') {
      steps {
        container('git') {
          script {
            sh "git config --global --add safe.directory ${env.WORKSPACE}"

            def commitCount = sh(
              script: "git rev-list --count HEAD",
              returnStdout: true
            ).trim().toInteger()

            if (commitCount < 2) {
              echo "Primer build o historial insuficiente — forzando build"
              env.SHOULD_BUILD = 'true'
            } else {
              def changes = sh(
                script: "git diff --name-only HEAD~1 HEAD",
                returnStdout: true
              ).trim()

              echo "Archivos modificados: ${changes}"

              if (changes.contains('Dockerfile') ||
                  changes.contains('index.html') ||
                  changes.contains('src/') ||
                  changes.contains('docker-entrypoint.sh')) {
                env.SHOULD_BUILD = 'true'
                echo "Cambios detectados — se procedera con el build"
              } else {
                env.SHOULD_BUILD = 'false'
                echo "Sin cambios en la app — se omiten build y push"
              }
            }
          }
        }
      }
    }

    stage('Build & Push') {
      when {
        environment name: 'SHOULD_BUILD', value: 'true'
      }
      steps {
        container('kaniko') {
          sh """
            /kaniko/executor \
              --context=dir://${env.WORKSPACE} \
              --dockerfile=${env.WORKSPACE}/Dockerfile \
              --destination=${IMAGE}:${TAG} \
              --destination=${IMAGE}:latest
          """
        }
      }
    }

    stage('Update GitOps') {
      when {
        environment name: 'SHOULD_BUILD', value: 'true'
      }
      steps {
        container('git') {
          withCredentials([usernamePassword(
            credentialsId: 'github-credentials',
            usernameVariable: 'USER',
            passwordVariable: 'PASS'
          )]) {
            sh """
              git clone https://\$USER:\$PASS@github.com/jsantacruzpy/app-demo-gitops
              cd app-demo-gitops
              sed -i 's|image: ${IMAGE}:.*|image: ${IMAGE}:${TAG}|' base/deployment.yaml
              git config user.email "jenkins@lab.local"
              git config user.name "Jenkins"
              git add .
              git commit -m "ci: update image to ${TAG}"
              git push
            """
          }
        }
      }
    }
  }

  post {
    success {
      echo "Pipeline exitoso — imagen pusheada: ${env.IMAGE}:${env.TAG}"
    }
    failure {
      echo "Pipeline fallido — revisar logs del stage en rojo"
    }
    always {
      echo "Pipeline finalizado — build ejecutado: ${env.SHOULD_BUILD}"
    }
  }
}
```

### Resultado
Pipeline omite build y push cuando no hay cambios relevantes en la app.

---

## [2026-07-15] — Feature: mostrar hostname del pod en la UI

### Qué se hizo
Se modificó la app para mostrar el hostname del contenedor (nombre del pod en k8s)
en la página web. Esto permite verificar el balanceo de carga entre réplicas al
hacer refresh en el browser. Se agregó un script de inicio que inyecta el hostname
en el HTML antes de arrancar nginx.

### Archivos creados/modificados

#### `index.html`
```html
<!DOCTYPE html>
<html>
<head>
  <style>
    body { font-family: Arial, sans-serif; text-align: center; margin-top: 50px; }
    .hostname { color: #e74c3c; font-size: 1.5em; font-weight: bold; }
    .version  { color: #7f8c8d; font-size: 0.9em; }
  </style>
</head>
<body>
  <h1>CI/CD Demo</h1>
  <p>Pod: <span class="hostname">__HOSTNAME__</span></p>
  <p class="version">Refresh para ver balanceo entre pods</p>
</body>
</html>
```

#### `docker-entrypoint.sh` (nuevo)
```bash
#!/bin/sh

# Reemplazar placeholder __HOSTNAME__ con el hostname real del contenedor
# En Kubernetes el hostname del contenedor es el nombre del pod
sed -i "s|__HOSTNAME__|$(hostname)|g" /usr/share/nginx/html/index.html

# Arrancar nginx en foreground
nginx -g "daemon off;"
```

#### `Dockerfile`
```dockerfile
FROM nginx:alpine

# Copiar y dar permisos al script de inicio
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Copiar el HTML con el placeholder __HOSTNAME__
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

# El script inyecta el hostname y arranca nginx
CMD ["/docker-entrypoint.sh"]
```

### Comandos ejecutados
```bash
git add index.html docker-entrypoint.sh Dockerfile
git commit -m "feat: mostrar hostname del pod en la UI"
git push
```

### Resultado
- Jenkins detectó cambios en `docker-entrypoint.sh` e `index.html`
- Kaniko buildeó nueva imagen y pusheó como `jsantacruzpy/app-demo:19`
- ArgoCD sincronizó y desplegó la nueva imagen en k3s
- Al acceder a la app se muestra el nombre del pod

---

## [2026-07-16] — Fix: IP fija para ingress-nginx controller en MetalLB

### Qué se hizo
Se fijó una IP estática del pool de MetalLB para el ingress-nginx controller
para evitar que cambie de IP en cada redespliegue. El cambio se hizo en el
`helmrelease.yaml` del repo `cluster-gitops`.

### Archivos modificados

#### `cluster-gitops/ingress-nginx/helmrelease.yaml`
```yaml
controller:
  service:
    type: LoadBalancer
    annotations:
      metallb.universe.tf/loadBalancerIPs: 10.10.20.250  # ← IP fija agregada
```

### Comandos ejecutados
```bash
cd cluster-gitops
git add ingress-nginx/helmrelease.yaml
git commit -m "feat: fijar IP estatica del ingress-nginx controller"
git push
```

### Resultado
El ingress-nginx controller siempre obtiene la misma IP de MetalLB.

---

## [2026-07-16] — Services ArgoCD y Jenkins cambiados a ClusterIP

### Qué se hizo
ArgoCD y Jenkins estaban expuestos con `type: LoadBalancer` consumiendo IPs del
pool de MetalLB innecesariamente. Al tener Ingress configurado, el acceso externo
ya está cubierto por el ingress-nginx controller. Se cambiaron a `ClusterIP` para
liberar IPs del pool.

### Comandos ejecutados
```bash
# Editar service de ArgoCD
kubectl edit svc argocd-server -n argocd
# Cambios: type: ClusterIP, eliminar campos exclusivos de LoadBalancer

# Editar service de Jenkins
kubectl edit svc jenkins -n jenkins
# Cambios: type: ClusterIP, eliminar allocateLoadBalancerNodePorts,
#          loadBalancerSourceRanges, externalTrafficPolicy, nodePort
```

### Campos eliminados del svc de Jenkins
```yaml
# Estos campos solo son válidos con type: LoadBalancer — se eliminaron
allocateLoadBalancerNodePorts: false
loadBalancerSourceRanges:
- 0.0.0.0/0
externalTrafficPolicy: Cluster
nodePort: 32712
```

### Resultado
- IPs del pool MetalLB liberadas
- Acceso a ArgoCD y Jenkins únicamente via Ingress (jenkins.lab.local / argocd.lab.local)

---

## [2026-07-16] — Feature: hostname del pod en la UI (corrección Dockerfile)

### Qué se hizo
En el deploy anterior el `docker-entrypoint.sh` no se estaba ejecutando porque
el `Dockerfile` no tenía las instrucciones para copiarlo. Se corrigió el Dockerfile
agregando las instrucciones faltantes.

### Problema encontrado
```
# La UI mostraba el placeholder sin reemplazar
Pod: __HOSTNAME__
```

### Archivos modificados

#### `Dockerfile` — agregar entrypoint
```dockerfile
FROM nginx:alpine

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

CMD ["/docker-entrypoint.sh"]
```

### Resultado
La UI muestra el nombre real del pod al cargar la página.

---

## [2026-07-16] — Feature: scale a 3 réplicas en app-demo

### Qué se hizo
Se escaló el deployment de app-demo a 3 réplicas para probar el balanceo de
carga entre pods. Al hacer refresh en el browser se puede ver el hostname cambiar
entre los 3 pods.

### Archivos modificados

#### `app-demo-gitops/base/deployment.yaml`
```yaml
spec:
  replicas: 3    # ← cambiado de 1 a 3
```

### Comandos ejecutados
```bash
cd app-demo-gitops
git add base/deployment.yaml
git commit -m "feat: scale app-demo to 3 replicas"
git push
```

### Resultado
3 pods corriendo. Balanceo de carga verificado haciendo refresh en el browser.

---

## [2026-07-17] — Feature: webhook GitHub → Jenkins con ngrok

### Qué se hizo
Se configuró un webhook en GitHub para triggerear el pipeline de Jenkins
automáticamente en cada push, reemplazando el Poll SCM de 2 minutos.
Como Jenkins tiene IP privada, se usó ngrok como túnel para exponer
el endpoint `/github-webhook/` de Jenkins a internet.

### Componentes configurados

**ngrok** — túnel desde internet hacia el ingress-nginx controller:
```bash
ngrok http --host-header=jenkins.lab.local 10.10.20.250:80

# URL generada:
# https://creamed-brittle-countless.ngrok-free.dev
```

**Jenkins** — habilitar trigger por webhook:
```
app-demo job
  └── Configure
        └── Build Triggers
              └── ✅ GitHub hook trigger for GITScm polling
              └── ❌ Poll SCM  (desactivado)
```

**GitHub** — agregar webhook:
```
github.com/jsantacruzpy/app-demo
  └── Settings
        └── Webhooks
              └── Add webhook
                    ├── Payload URL: https://creamed-brittle-countless.ngrok-free.dev/github-webhook/
                    ├── Content type: application/json
                    └── Events: Just the push event
```

### Problema encontrado
```
# GitHub recibía 403 al intentar enviar el webhook
HTTP 403 Forbidden
# Causa: protección CSRF de Jenkins rechazaba el request
```

### Fix — deshabilitar CSRF via Script Console
```
Manage Jenkins
  └── Script Console
        └── Ejecutar:
```
```groovy
import hudson.security.csrf.DefaultCrumbIssuer
import jenkins.model.Jenkins

def instance = Jenkins.instance
instance.setCrumbIssuer(null)
instance.save()
```

### Resultado
- Webhook funcionando — pipeline arranca instantáneamente en cada push
- Verificado con `Recent Deliveries` en GitHub mostrando `200 OK`

---

## Estado actual del repositorio

```
app-demo/
├── Dockerfile
├── Jenkinsfile
├── docker-entrypoint.sh
└── index.html
```

### Imagen en DockerHub
- Última versión: `jsantacruzpy/app-demo:latest`
- Tags disponibles: desde `:3` hasta `:latest`

### Pipeline actual
| Stage | Descripción |
|-------|-------------|
| Check Changes | Detecta si hubo cambios en archivos relevantes |
| Build & Push | Kaniko buildea y pushea imagen a DockerHub |
| Update GitOps | Actualiza tag en app-demo-gitops |

### Trigger
- Webhook GitHub → ngrok → Jenkins (instantáneo en cada push)
- Solo ejecuta build si cambiaron: `Dockerfile`, `index.html`, `src/`, `docker-entrypoint.sh`

### Réplicas
- app-demo corriendo con 3 réplicas
- Balanceo de carga verificado via Ingress
