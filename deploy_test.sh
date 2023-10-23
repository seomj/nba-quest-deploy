#!/bin/bash

# test용 변수들
APP_NAME=test-ctn
SVC_NAME=test-svc
DEPLOY_NAME=test-deploy
NAMESPACE_NAME=eks-test
TITLE=seomj   #provisioning의 TITLE과 통일

# aws configure function
function aws_confingure(){
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"
  aws configure set default.output "$AWS_OUTPUT_FORMAT"

  # Error 발생 시
    if [ $? -ne 0 ]; then
      echo "Failed to configure AWS CLI."
      #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to configure AWS CLI."}' -H "Content-Type: application/json" $API_ENDPOINT
      exit 1
    else
      echo "AWS CLI configured successfully."
    fi
}

# create LB function
function create_lb(){
  if [ "$LB_CONTROLLER" == true ]; then

    eksctl utils associate-iam-oidc-provider --region=$AWS_DEFAULT_REGION --cluster=$AWS_EKS_NAME --approve
    
    # IAM Role
    AWS_USER_ID=$(aws sts get-caller-identity | jq -r .UserId)

    eksctl create iamserviceaccount \
      --cluster=$AWS_EKS_NAME \
      --namespace=kube-system \
      --region=$AWS_DEFAULT_REGION \
      --name=aws-load-balancer-controller \
      --role-name AmazonEKSLoadBalancerControllerRole \
      --attach-policy-arn arn:aws:iam::$AWS_USER_ID:policy/AWSLoadBalancerControllerIAMPolicy \
      --approve

    # error
    if [ $? -ne 0 ]; then
      echo "Failed to create IAM service account."
      #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to create IAM service account."}' -H "Content-Type: application/json" $API_ENDPOINT
      exit 1
    fi

    # repo
    helm repo add eks https://aws.github.io/eks-charts && helm repo update eks

    #error
    if [ $? -ne 0 ]; then
      echo "Failed to add Helm repository or update."
      #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to add Helm repository or update."}' -H "Content-Type: application/json" $API_ENDPOINT
      exit 1
    fi

    # install
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=$AWS_EKS_NAME \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller && sleep 10

    # error
    if [ $? -ne 0 ]; then
      echo "Failed to install AWS Load Balancer Controller using Helm."
      #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to install AWS Load Balancer Controller using Helm."}' -H "Content-Type: application/json" $API_ENDPOINT
      exit 1
    fi
  fi
}


# check aws configure
# AWS credentials file path
AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"
PROFILE_NAME="default"

if [ -f "$AWS_CREDENTIALS_FILE" ]; then
  # Extract aws_access_key_id and aws_secret_access_key
  ACCESS_KEY_ID=$(grep -A2 "\[$PROFILE_NAME\]" "$AWS_CREDENTIALS_FILE" | grep aws_access_key_id | awk '{print $3}')
  SECRET_ACCESS_KEY=$(grep -A2 "\[$PROFILE_NAME\]" "$AWS_CREDENTIALS_FILE" | grep aws_secret_access_key | awk '{print $3}')
  
  if [ "$ACCESS_KEY_ID" != "$AWS_ACCESS_KEY_ID" ] || [ "$SECRET_ACCESS_KEY" != "$SECRET_ACCESS_KEY" ]; then
    aws_confingure
  fi
else
  aws_confingure
fi


# kubeconfig
EKS_LIST=$(aws eks list-clusters --region $AWS_DEFAULT_REGION | jq -r '.clusters[]')
EKS_EXIST=false

for EKS in $EKS_LIST; do
  if [ "$EKS" == "$AWS_EKS_NAME" ]; then
    aws eks update-kubeconfig --region $AWS_DEFAULT_REGION --name $AWS_EKS_NAME
    echo "Kubeconfig updated successfully for EKS cluster '$AWS_EKS_NAME'."
    # Error 발생 시
    if [ $? -ne 0 ]; then
      echo "Failed to update kubeconfig for EKS cluster '$AWS_EKS_NAME'."
      #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to update kubeconfig for EKS cluster '$AWS_EKS_NAME'."}' -H "Content-Type: application/json" $API_ENDPOINT
      exit 1
    fi
    # eks가 있다면 true
    EKS_EXIST=true
    break
  fi
done

# eks가 없다면
if [ "$EKS_EXIST" == false ]; then
  echo "EKS cluster '$AWS_EKS_NAME' not found in region '$AWS_DEFAULT_REGION'."
  #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"EKS cluster '$AWS_EKS_NAME' not found in region '$AWS_DEFAULT_REGION'."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi


# NLB
DEPLOYMENT_LIST=$(kubectl get deployments -n kube-system -o custom-columns="NAME:.metadata.name" --no-headers)
LBC_EXIST=false

# LB Controller를 사용한다면 NLB 생성
if [ "$LB_CONTROLLER" == true ]; then
  # LBC가 있는지 확인
  for DEPLOYMENT in $DEPLOYMENT_LIST; do
    if [ "$DEPLOYMENT" == "aws-load-balancer-controller" ]; then
      LBC_EXIST=true
      break
    fi
  done
  
  # LBC가 없다면 Create LB
  if [ "$LBC_EXIST" == false ]; then
    create_lb
  fi

  # LBC가 잘 돌아가는지 확인
  LB_STATUS=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')

  if [ "$LB_STATUS" != True ]; then
    echo "Load balancer controller is not available."
    #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Load balancer controller is not available."}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  else
    echo "Load balancer controller is available."
  fi
fi


# create ns
NS_LIST=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
NS_EXIST=false

# ns가 있다면
for NS in $NS_LIST; do
  if [ "$NS" == "$NAMESPACE_NAME" ]; then
    NS_EXIST=true
    break
  fi
done

# ns가 없다면
if [ "$NS_EXIST" == false ]; then
  kubectl create namespace "$NAMESPACE_NAME"
  if [ $? -ne 0 ]; then
    echo "Failed to create namespace."
    #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Load balancer controller is not available."}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  else
    echo "Namespace created successfully."
  fi
else
  echo "Namespace $NAMESPACE_NAME already exists."
fi

# secret



# svc
cat <<EOF > service.yaml
apiVersion: v1
kind: Service
metadata:
  name: $SVC_NAME
  namespace: $NAMESPACE_NAME
EOF

if [ $LB_CONTROLLER == true ]; then
  cat <<EOF >> service.yaml
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
EOF

  if [ -n "$LB_SUBNETS" ]; then
    echo "    service.beta.kubernetes.io/aws-load-balancer-subnets: $LB_SUBNETS" >> service.yaml
  fi
fi

cat <<EOF >> service.yaml
  labels:
    quest: $TITLE
spec:
  selector:
    quest: $TITLE
  ports:
    - protocol: TCP
      port: $PORT
      targetPort: $PORT
  type: LoadBalancer
EOF
#provisioning의 TITLE과 통일


# deployment
cat <<EOF > deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE_NAME
  labels:
    quest: $TITLE
spec:
  replicas: $DEPLOY_REPLICAS
  selector:
    matchLabels:
      quest: $TITLE
  template:
    metadata:
      labels:
        quest: $TITLE
    spec:
      containers:
      - name: $APP_NAME   # 임의로 이름 지정 - 따로 입력받을 예정
        image: $DEPLOY_CONTAINER_IMAGE
        ports:
        - containerPort: $PORT
EOF

kubectl apply -f secret.yaml
if [ $? -ne 0 ]; then
  echo "Failed to apply secert configuration."
  #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to apply secret configuration."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi

kubectl apply -f service.yaml 
if [ $? -ne 0 ]; then
  echo "Failed to apply service configuration."
  #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to apply service configuration."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi

kubectl apply -f deployment.yaml 
if [ $? -ne 0 ]; then
  echo "Failed to apply deployment configuration."
  #curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Failed","emessage":"Failed to apply deployment configuration."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi

# 작업 종료
echo "Success Deploy!"
#curl -i -X POST -d '{"id":'$ID',"progress":"deployment","state":"Success","emessage":"Success Deploy!"}' -H "Content-Type: application/json" $API_ENDPOINT