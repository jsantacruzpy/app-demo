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

    // Detectar si hubo cambios en archivos relevantes de la app
    // Compara el commit actual contra el anterior
    stage('Check Changes') {
      steps {
        container('git') {
          script {
            def changes = sh(
              // Lista archivos modificados entre el commit anterior y el actual
              // HEAD~1 es el commit anterior, HEAD es el actual
              script: "git diff --name-only HEAD~1 HEAD",
              returnStdout: true
            ).trim()

            echo "Archivos modificados: ${changes}"

            // Si cambió Dockerfile, index.html o cualquier archivo de src/
            // marcamos que hay que buildear
            if (changes.contains('Dockerfile') ||
                changes.contains('index.html') ||
                changes.contains('src/')) {
              env.SHOULD_BUILD = 'true'
              echo "Cambios detectados en la app — se va a buildear"
            } else {
              env.SHOULD_BUILD = 'false'
              echo "Sin cambios en la app — se omite el build"
            }
          }
        }
      }
    }

    // Solo ejecuta si SHOULD_BUILD es true
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

    // Solo ejecuta si hubo build exitoso
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

  // Notificar resultado del pipeline al final
  post {
    success {
      echo "Pipeline exitoso — imagen: ${env.IMAGE}:${env.TAG}"
    }
    failure {
      echo "Pipeline fallido — revisar logs"
    }
    skipped {
      echo "Build omitido — sin cambios en la app"
    }
  }
}