#!/bin/bash

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
  labels:
    app: quest
spec:
  selector:
    app: quest
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
    app: quest
spec:
  replicas: $DEPLOY_REPLICAS
  selector:
    matchLabels:
      app: quest
  template:
    metadata:
      labels:
        app: quest
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