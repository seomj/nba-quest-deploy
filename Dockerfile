FROM ubuntu:20.04

LABEL purpose = "Deployment base image"

ENV ARCH=amd64 

RUN apt update && \
    apt install -y curl && \
    apt install -y unzip && \
    apt install -y jq

# kubectl
# version 1.27
RUN curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.27.4/2023-08-16/bin/linux/amd64/kubectl && \
    chmod +x ./kubectl && \
    mv ./kubectl /usr/local/bin/kubectl

#awscli
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install

#eksctl
RUN PLATFORM=$(uname -s)_$ARCH && \
    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz" && \
    tar -xzf "eksctl_$PLATFORM.tar.gz" -C /tmp && \
    rm "eksctl_$PLATFORM.tar.gz" && \
    mv /tmp/eksctl /usr/local/bin

#helm
RUN curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
RUN chmod 700 get_helm.sh
RUN ./get_helm.sh

#sh
COPY deploy_test.sh /deploy/deploy_test.sh
RUN chmod +x /deploy/deploy_test.sh