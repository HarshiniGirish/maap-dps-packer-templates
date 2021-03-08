#!/bin/bash

PACKER_LOG=1
DATE=$(date '+%Y%m%d')

source_ami=$1
subnet_id=$2

for i in `echo mozart metrics grq factotum autoscale cont_int`; do
    packer build -var "access_key=$(grep aws_access_key_id $HOME/.aws/credentials | head -1 | awk '{print $3}')" \
               -var "secret_key=$(grep aws_secret_access_key $HOME/.aws/credentials | head -1 | awk '{print $3}')" \
               -var "token=$(grep aws_session_token $HOME/.aws/credentials | head -1 | awk '{print $3}')" \
               -var "region=$(grep region $HOME/.aws/config | head -1 | awk '{print $3}')" \
               -var "ami_name=centos-7-x86_64-${i}-py3-${DATE}" \
               -var "source_ami=${source_ami}" \
               -var "volume_size=30" \
               -var "subnet_id=${subnet_id}" \
               -var "hysds_component=${i}" \
               hysds_aws.json
done
