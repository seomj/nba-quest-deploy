pipeline {
    agent any
    
    // 환경변수 지정
    environment {
        REGION='ap-northeast-1'
        ECR_PATH='dkr.ecr.ap-northeast-1.amazonaws.com'
        ACCOUNT_ID='622164100401'
        AWS_CREDENTIAL_NAME='NBA-AWS-Credential-v2'
        IMAGE_NAME = 'nba-quest-deploy'
        IMAGE_VERSION = "0.7.0"
    }

    stages {
        stage('Checkout') {
            steps {
                git branch: 'main',
                    credentialsId: 'NBA-Quest-Deploy-Gitops-Pipeline-Credential',
                    url: 'https://github.com/seomj/nba-quest-deploy.git'
            }
        }
        
        stage('build') {
            steps {
                sh '''
        		 docker build -t $ACCOUNT_ID.$ECR_PATH/$IMAGE_NAME:$IMAGE_VERSION .
        		 '''
            }
        }
    
        stage('upload aws ECR') {
            steps {                
                script {
                    docker.withRegistry("https://$ACCOUNT_ID.$ECR_PATH", "ecr:$REGION:$AWS_CREDENTIAL_NAME") {
                        docker.image("$ACCOUNT_ID.$ECR_PATH/$IMAGE_NAME:$IMAGE_VERSION").push()
                    }
                }
            } 
        }
    }
}