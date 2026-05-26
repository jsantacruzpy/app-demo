pipeline {
  // Define que este pipeline corre en un pod de Kubernetes
  // El plugin de Kubernetes crea este pod automáticamente en k3s
  agent {
    kubernetes {
      yaml """
apiVersion: v1
kind: Pod
spec:
  containers:

  # Contenedor 1: Kaniko
  # Responsable de construir la imagen Docker sin necesitar daemon
  # Usa el secret de DockerHub para autenticarse y hacer push
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    # sleep mantiene el contenedor vivo mientras Jenkins ejecuta los stages
    command: ['sleep', '9999']
    volumeMounts:
    # Monta el secret de DockerHub en la ruta que Kaniko espera
    # Kaniko lee /kaniko/.docker/config.json para autenticarse
    - name: dockerhub-secret
      mountPath: /kaniko/.docker

  # Contenedor 2: Git
  # Responsable de clonar y actualizar el repo GitOps
  # Kaniko no tiene git, por eso usamos un contenedor separado
  - name: git
    image: alpine/git
    command: ['sleep', '9999']

  volumes:
  # El secret dockerhub-secret fue creado con kubectl create secret
  # Contiene las credenciales de DockerHub en formato config.json
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
    // Nombre de la imagen en DockerHub: usuario/repositorio
    IMAGE = "jsantacruzpy/app-demo"
    // Tag de la imagen: usamos el numero de build de Jenkins
    // Cada build genera un tag unico: :1, :2, :3, etc.
    TAG   = "${env.BUILD_NUMBER}"
  }

  stages {

    // Stage 1: Build y Push de la imagen
    // Kaniko lee el Dockerfile del workspace (clonado por Jenkins)
    // construye la imagen layer por layer y la pushea a DockerHub
    stage('Build & Push') {
      steps {
        // Ejecutar dentro del contenedor kaniko del pod
        container('kaniko') {
          sh """
            /kaniko/executor \
              --context=dir://${env.WORKSPACE} \
              --dockerfile=${env.WORKSPACE}/Dockerfile \
              --destination=${IMAGE}:${TAG} \
              --destination=${IMAGE}:latest
          """
          // --context: directorio donde esta el codigo (workspace de Jenkins)
          // --dockerfile: path al Dockerfile
          // --destination: imagen con tag numerico (ej: jsantacruzpy/app-demo:5)
          // --destination: tag latest apunta siempre al build mas reciente
        }
      }
    }

    // Stage 2: Actualizar el repo GitOps
    // Jenkins modifica el deployment.yaml con el nuevo tag de imagen
    // ArgoCD detecta ese cambio y despliega automaticamente en k3s
    stage('Update GitOps') {
      steps { 
        // Ejecutar dentro del contenedor git del pod
        container('git') {
          // Usar las credenciales de GitHub almacenadas en Jenkins
          // USER y PASS se inyectan como variables de entorno
          // Jenkins enmascara automaticamente PASS en los logs
          withCredentials([usernamePassword(
            credentialsId: 'github-credentials',
            usernameVariable: 'USER',
            passwordVariable: 'PASS'
          )]) {
            sh """
              # Clonar el repo GitOps usando el token de GitHub
              git clone https://\$USER:\$PASS@github.com/jsantacruzpy/app-demo-gitops

              cd app-demo-gitops

              # Reemplazar el tag de la imagen en el deployment.yaml
              # sed busca la linea que contiene 'image: jsantacruzpy/app-demo:'
              # y reemplaza el tag por el numero de build actual
              sed -i 's|image: ${IMAGE}:.*|image: ${IMAGE}:${TAG}|' base/deployment.yaml

              # Configurar identidad de git para el commit
              git config user.email "jenkins@lab.local"
              git config user.name "Jenkins"

              git add .
              git commit -m "ci: update image to ${TAG}"

              # Push al repo GitOps
              # ArgoCD detecta este commit y sincroniza el cluster
              git push
            """
          }
        }
      }
    }
  }
}