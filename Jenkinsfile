// Jenkinsfile
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
        container('kaniko') {
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
