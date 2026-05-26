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
        // Fix de permisos: git no confía en directorios
        // con owner diferente al usuario actual del contenedor
        sh "git config --global --add safe.directory ${env.WORKSPACE}"
        
        // Verificar si existe historial suficiente para comparar
        // En el primer build o con shallow clone HEAD~1 no existe
        def commitCount = sh(
          script: "git rev-list --count HEAD",
          returnStdout: true
        ).trim().toInteger()

        if (commitCount < 2) {
          // Primer commit o sin historial — buildear siempre
          echo "Primer build o historial insuficiente — forzando build"
          env.SHOULD_BUILD = 'true'
        } else {
          // Comparar archivos modificados entre commits
          def changes = sh(
            script: "git diff --name-only HEAD~1 HEAD",
            returnStdout: true
          ).trim()

          echo "Archivos modificados: ${changes}"

          if (changes.contains('Dockerfile') ||
              changes.contains('index.html') ||
              changes.contains('src/')) {
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
    always {
      echo "Pipeline finalizado — SHOULD_BUILD: ${env.SHOULD_BUILD}"
    }
  }
}