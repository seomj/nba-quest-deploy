#!/bin/bash

# title 소문자 변환
TITLE=${TITLE,,}

# create LB function
function create_lb(){
  eksctl utils associate-iam-oidc-provider --region=$AWS_DEFAULT_REGION --cluster=$AWS_EKS_NAME --approve
  
  # IAM Role
  AWS_USER_ID=$(aws sts get-caller-identity | jq -r .UserId)

  # check role name
  if [ "$LB_ROLE" == True ]; then
    random=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | sed 1q)
    AWS_LBC_ROLE=AmazonEKSLoadBalancerControllerRoleQUEST-$random
  else
    AWS_LBC_ROLE=AmazonEKSLoadBalancerControllerRoleQUEST
  fi

  eksctl create iamserviceaccount \
    --cluster=$AWS_EKS_NAME \
    --namespace=kube-system \
    --region=$AWS_DEFAULT_REGION \
    --name=aws-load-balancer-controller \
    --role-name $AWS_LBC_ROLE \
    --attach-policy-arn arn:aws:iam::$AWS_USER_ID:policy/AWSLoadBalancerControllerIAMPolicyQUEST \
    --approve

  # error
  if [ $? -ne 0 ]; then
    echo "========== SA 생성 실패 =========="
    eksctl delete iamserviceaccount --cluster=$AWS_EKS_NAME --namespace=kube-system --name=aws-load-balancer-controller
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
  # 0으로 잘 들어가는지 체크 필요
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

  TAGS_JSON=$(aws ecr-public describe-images --repository-name $AWS_ECR_REPO)
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
  TAGS_JSON_PRI=$(aws ecr list-images --repository-name $AWS_ECR_REPO)
  TAGS_LIST_PRI=($(echo $TAGS_JSON_PRI | jq -r '.imageIds[].imageTag'))

  # tag 값 있는지 확인
  for tag in "${TAGS_LIST_PRI[@]}"; do
    if [ $tag == $AWS_ECR_REPO_TAG ]; then
      IMAGE_PRI_EXIST=true
      break
    fi
  done
}


# check image
AWS_ECR_REPO=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d ":" -f 1)
AWS_ECR_REPO_TAG=$(echo "$DEPLOY_CONTAINER_IMAGE" | cut -d ":" -f 2)


IMAGE_PUB_EXIST=false
IMAGE_PRI_EXIST=false

# public 검색
public_ecr

# public에 없다면 private 검색
if [ $IMAGE_PUB_EXIST != true ]; then
  private_ecr
fi

# 이미지가 존재하지 않는다면
if [ $IMAGE_PUB_EXIST == false ] && [ $IMAGE_PRI_EXIST == false ]; then
  echo "========== Image '$DEPLOY_CONTAINER_IMAGE' does not exist. =========="
  # curl
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
LB_STATUS=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')

while [ "$LB_STATUS" != True ]
do
  LBC_EXIST=false

  # LBC가 있는지 확인
  for DEPLOYMENT in $DEPLOYMENT_LIST; do
    # LBC가 있다면
    if [ "$DEPLOYMENT" == "aws-load-balancer-controller" ]; then
      LBC_EXIST=true
      break
    fi
  done

  # LBC가 없다면
  if [ "$LBC_EXIST" == false ]; then
    create_lb
  # LBC가 있다면
  else
    echo "LBC가 있다."
  fi
done 

# 한번 더 점검
if [ "$LB_STATUS" == True ]; then
  echo "========== Load balancer controller is available. =========="
else
  echo "========== Load balancer controller를 사용할 수 없습니다. =========="
  curl -i -X POST -d '{"id":'$ID',"progress":"deploy","state":"failed","emessage":"Load balancer controller를 사용할 수 없습니다."}' -H "Content-Type: application/json" $API_ENDPOINT
  exit 1
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
      port: $PORT
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