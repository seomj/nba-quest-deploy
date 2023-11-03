#!/bin/bash

# title 소문자 변환
TITLE=${TITLE,,}

AWS_USER_ID=$(aws sts get-caller-identity | jq -r .UserId)

# create LB function
function create_lb(){
  eksctl utils associate-iam-oidc-provider --region=$AWS_DEFAULT_REGION --cluster=$AWS_EKS_NAME --approve

  if [ $? -ne 0 ]; then
    echo "========== IAM OIDC 공급자와 EKS 연결에 실패했습니다. =========="
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"IAM OIDC 공급자와 EKS 연결 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  fi

  oidc_id=$(aws eks describe-cluster --name $AWS_EKS_NAME --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

  cat >load-balancer-role-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::$AWS_USER_ID:oidc-provider/oidc.eks.$AWS_DEFAULT_REGION.amazonaws.com/id/$oidc_id"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.$AWS_DEFAULT_REGION.amazonaws.com/id/$oidc_id:aud": "sts.amazonaws.com",
                    "oidc.eks.$AWS_DEFAULT_REGION.amazonaws.com/id/$oidc_id:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
                }
            }
        }
    ]
}
EOF

  if [ "$LB_ROLE" == True ]; then
    random=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | sed 1q)
    AWS_LBC_ROLE=AmazonEKSLoadBalancerControllerRoleQUEST-$random
  else
    AWS_LBC_ROLE=AmazonEKSLoadBalancerControllerRoleQUEST
  fi

  aws iam create-role \
    --role-name $AWS_LBC_ROLE \
    --assume-role-policy-document file://"load-balancer-role-trust-policy.json"

  if [ $? -ne 0 ]; then
    echo "========== Role 생성에 실패했습니다. =========="
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"Role 생성 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  fi

  aws iam attach-role-policy \
    --policy-arn arn:aws:iam::$AWS_USER_ID:policy/AWSLoadBalancerControllerIAMPolicyQUEST \
    --role-name $AWS_LBC_ROLE

  if [ $? -ne 0 ]; then
    echo "========== Role과 Policy 연결에 실패했습니다. =========="
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"Role과 Policy 연결 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  fi

  cat >aws-load-balancer-controller-service-account.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::$AWS_USER_ID:role/$AWS_LBC_ROLE
EOF

  kubectl apply -f aws-load-balancer-controller-service-account.yaml
  if [ $? -ne 0 ]; then
    echo "========== SA 생성에 실패했습니다. =========="
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"SA 생성 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  fi

  # install
  helm repo add eks https://aws.github.io/eks-charts && \
  helm repo update eks && \
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$AWS_EKS_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller && sleep 20

  # error
  if [ $? -ne 0 ]; then
    echo "========== Load Balancer Controller 설치에 실패했습니다. =========="
    helm uninstall aws-load-balancer-controller -n kube-system
    eksctl delete iamserviceaccount --cluster=$AWS_EKS_NAME --namespace=kube-system --name=aws-load-balancer-controller
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"Load Balancer Controller 설치에 실패했습니다."}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  fi
}

function public_ecr(){
  aws configure set default.region "us-east-1"
  
  AWS_PUB_ECR_REPO=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d "/" -f 3 | cut -d ":" -f 1)
  TAGS_JSON=$(aws ecr-public describe-images --repository-name $AWS_PUB_ECR_REPO)
  TAGS_LIST=($(echo $TAGS_JSON | jq -r '.imageDetails[].imageTags[]'))
  
  # tag 값 있는지 확인
  for tag in "${TAGS_LIST[@]}"; do
    if [ $tag == $AWS_ECR_REPO_TAG ]; then
      IMAGE_PUB_EXIST=true
      break
    fi
  done

  aws configure set default.region "$AWS_DEFAULT_REGION"
}

function private_ecr(){
  AWS_PRI_ECR_REPO=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d "/" -f 2 | cut -d ":" -f 1)
  TAGS_JSON_PRI=$(aws ecr list-images --repository-name $AWS_PRI_ECR_REPO --region $AWS_DEFAULT_REGION)
  TAGS_LIST_PRI=($(echo $TAGS_JSON_PRI | jq -r '.imageIds[].imageTag'))

  # tag 값 있는지 확인
  for tag in "${TAGS_LIST_PRI[@]}"; do
    if [ $tag == $AWS_ECR_REPO_TAG ]; then
      IMAGE_PRI_EXIST=true
      break
    fi
  done
}

function dockerhub(){
  DOCKER_NS=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d "/" -f 1)
  DOCKER_REPO=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d "/" -f 2 | cut -d ":" -f 1)
  DOCKER_TAG=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d "/" -f 2 | cut -d ":" -f 2)

  if [[ $DEPLOY_CONTAINER_IMAGE != *"/"* ]]; then
    dockerhub_response=$(curl -s -o /dev/null -w "%{http_code}" https://hub.docker.com/v2/repositories/library/$DOCKER_REPO/tags/$DOCKER_TAG)
  else
    dockerhub_response=$(curl -s -o /dev/null -w "%{http_code}" https://hub.docker.com/v2/namespaces/$DOCKER_NS/repositories/$DOCKER_REPO/tags/$DOCKER_TAG)
  fi
}

# check image
AWS_ECR_REPO_TAG=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d ":" -f 2)

IMAGE_PUB_EXIST=false
IMAGE_PRI_EXIST=false
dockerhub_response=404

if [[ $DEPLOY_CONTAINER_IMAGE == *"$AWS_USER_ID"* ]]; then
  echo "====== private ecr search ====="
  private_ecr
elif [[ $DEPLOY_CONTAINER_IMAGE == *"public"* ]]; then
  echo "====== public ecr search ====="
  public_ecr
else
  echo "====== docker hub search ====="
  dockerhub
fi

# 이미지가 존재하지 않는다면
if [ $IMAGE_PUB_EXIST == false ] && [ $IMAGE_PRI_EXIST == false ] && [ $dockerhub_response != 200 ]; then
  echo "========== Image '$DEPLOY_CONTAINER_IMAGE' does not exist. =========="
  curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"'$DEPLOY_CONTAINER_IMAGE'가 존재하지 않습니다."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
else
  echo "========== Image '$DEPLOY_CONTAINER_IMAGE' exists. =========="
fi


# kubeconfig
EKS_LIST=$(aws eks list-clusters --region $AWS_DEFAULT_REGION | jq -r '.clusters[]')
EKS_EXIST=false

for EKS in $EKS_LIST; do
  if [ "$EKS" == "$AWS_EKS_NAME" ]; then
    aws eks update-kubeconfig --region $AWS_DEFAULT_REGION --name $AWS_EKS_NAME
    echo "========== Kubeconfig updated successfully for EKS cluster '$AWS_EKS_NAME'. =========="
    # Error 발생 시
    if [ $? -ne 0 ]; then
      echo "========== '$AWS_EKS_NAME'의 kubeconfig로 업데이트할 수 없습니다. =========="
      curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"'$AWS_EKS_NAME'의 kubeconfig로 업데이트할 수 없습니다."}' -H "Content-Type: application/json" $API_ENDPOINT
      exit 1
    fi
    # eks가 있다면 true
    EKS_EXIST=true
    break
  fi
done

# eks가 없다면
if [ "$EKS_EXIST" == false ]; then
  echo "========== '$AWS_EKS_NAME'를 찾을 수 없습니다. =========="
  curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"'$AWS_EKS_NAME'를 찾을 수 없습니다."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi


# NLB
DEPLOYMENT_LIST=$(kubectl get deployments -n kube-system -o custom-columns="NAME:.metadata.name" --no-headers)

LBC_EXIST=false

# LBC가 있는지 확인
for DEPLOYMENT in $DEPLOYMENT_LIST; do
  # LBC가 있다면
  if [ "$DEPLOYMENT" == "aws-load-balancer-controller" ]; then
    LBC_EXIST=true
    break
  fi
done

if [ "$LBC_EXIST" == false ]; then
  create_lb
else
  echo "========== AWS Load Balancer Controller가 존재합니다. =========="
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
    echo "========== namespace 생성 실패 =========="
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"namespace 생성 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  else
    echo "========== Namespace created successfully. =========="
  fi
else
  echo "========== Namespace $NAMESPACE_NAME already exists. =========="
fi


# secret
if [ -n "$SECRET" ]; then
  cat <<EOF > secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: $TITLE-secret
  namespace: $NAMESPACE_NAME
type: Opaque
data:
EOF
  # 형식 변환
  converted_string=$(echo "$SECRET" | sed "s/'/\"/g")

  # base64
  for item in $(echo $converted_string | jq -c '.[]'); do
    key=$(echo "$item" | jq -r '.key')
    value=$(echo "$item" | jq -r '.value')
    base64_value=$(echo -n "$value" | base64)
    cat << EOF >> secret.yaml
  $key: $base64_value
EOF
  done

  kubectl apply -f secret.yaml
  if [ $? -ne 0 ]; then
    echo "========== secert 실패 =========="
    curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"secert 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
    exit 1
  fi
fi


# svc
cat <<EOF > service.yaml
apiVersion: v1
kind: Service
metadata:
  name: $SVC_NAME
  namespace: $NAMESPACE_NAME
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  labels:
    quest: $TITLE
spec:
  selector:
    quest: $TITLE
  ports:
    - protocol: TCP
      port: 80
      targetPort: $PORT
  type: LoadBalancer
EOF


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
      - name: $TITLE-ctn
        image: $DEPLOY_CONTAINER_IMAGE
        ports:
        - containerPort: $PORT
EOF

# secret이 있으면 추가
if [ -n "$SECRET" ]; then
  cat <<EOF >> deployment.yaml
        envFrom:
        - secretRef:
            name: $TITLE-secret
EOF
fi

kubectl apply -f service.yaml 
if [ $? -ne 0 ]; then
  echo "========== service 실패 =========="
  curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"service 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi

kubectl apply -f deployment.yaml 
if [ $? -ne 0 ]; then
  echo "========== deployment 실패 =========="
  curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"deployment 실패"}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
fi

# 작업 종료
echo "========== 배포 성공! =========="
curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"success","emessage":"배포 성공!"}' -H "Content-Type: application/json" $API_ENDPOINT