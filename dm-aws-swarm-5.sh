#!/bin/sh

createAwsDockerSwarmCluster(){

echo "Creating up Swarm Cluster: ${CLUSTERNAME}"

#Prepare AWS infrastructure
# Create VPC
VPC_ID=$(aws ec2 create-vpc  --cidr-block 10.0.0.0/16 --tag-specification ResourceType=vpc,Tags=['{Key=Name,Value='${CLUSTERNAME}'}'] --query 'Vpc.VpcId' --output text)

# Create Subnet
SUBNET_ID=$(aws ec2 create-subnet --cidr-block 10.0.1.0/24 --availability-zone eu-central-1a --vpc-id ${VPC_ID} --tag-specification ResourceType=subnet,Tags=['{Key=Name,Value='${CLUSTERNAME}'}'] --query 'Subnet.SubnetId' --output text)

# Create Route Table
RTB_ID=$(aws ec2 create-route-table --vpc-id ${VPC_ID} --tag-specification ResourceType=route-table,Tags=['{Key=Name,Value='${CLUSTERNAME}'}'] --query 'RouteTable.RouteTableId' --output text)

# Associate route table
RTBASSOC_ID=$(aws ec2 associate-route-table --route-table-id ${RTB_ID} --subnet-id ${SUBNET_ID} --query 'AssociationId' --output text)

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --tag-specification ResourceType=internet-gateway,Tags=['{Key=Name,Value='${CLUSTERNAME}'}'] --query 'InternetGateway.InternetGatewayId' --output text)

# Attach IGW to VPC
aws ec2 attach-internet-gateway --internet-gateway-id ${IGW_ID} --vpc-id ${VPC_ID}

#Create route from outside to VPC through IGW
aws ec2 create-route --destination-cidr-block 0.0.0.0/0 --route-table-id ${RTB_ID} --gateway-id ${IGW_ID}

# Set AMI ID 
#
# aws ec2 describe-images --owners self  099720109477 --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-2022*' --query 'Images[].[ImageId,Name]' --output text
#
#AMI_ID=ami-04aa66cdfe687d427 # (ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20220506)
AMI_ID=ami-0d672276deff62a7b # ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-20220331
#AMI_ID=ami-0b6d8a6db0c665fb7 # (ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-20200430)

# Create nodes with docker-machine (SG will be created automaticaly)
for i in {1..5}; do
	docker-machine create \
		-d amazonec2 \
		--amazonec2-region eu-central-1 \
		--amazonec2-vpc-id ${VPC_ID} \
		--amazonec2-subnet-id ${SUBNET_ID} \
		--amazonec2-security-group ${CLUSTERNAME} \
		--amazonec2-instance-type t2.micro \
		--amazonec2-ami ${AMI_ID} \
		${NODE_PREFIX}${i}
done

# Get Security Group ID
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filter 'Name=group-name,Values='${CLUSTERNAME}'' --query 'SecurityGroups[].GroupId' --output text)

# Set rules for the swarm
for p in 2377 7946 4789; do \
	aws ec2 authorize-security-group-ingress \
		--group-id ${SECURITY_GROUP_ID} \
		--protocol tcp \
		--port ${p} \
		--source-group ${SECURITY_GROUP_ID}
done

for p in 7946 4789; do \
	aws ec2 authorize-security-group-ingress \
		--group-id ${SECURITY_GROUP_ID} \
		--protocol udp \
		--port ${p} \
		--source-group ${SECURITY_GROUP_ID}
done

# Get first node's private IP
DS_MGR_IP=$(aws ec2 describe-instances --filters 'Name=tag:Name,Values='${NODE_PREFIX}'1' 'Name=instance-state-name,Values=running' --output text --query 'Reservations[].Instances[].[PrivateIpAddress]')

# Set first node's env
eval $(docker-machine env ${NODE_PREFIX}1)

# Init swarm
echo "Init swarm at ${NODE_PREFIX}1 addr ${DS_MGR_IP}..."
docker swarm init \
	--advertise-addr ${DS_MGR_IP}

# Get cluster token
TOKEN_WOKER=$(docker swarm join-token -q worker)
TOKEN_MANAGER=$(docker swarm join-token -q manager)

# Add workers to cluster
for i in 2 3; do
	eval $(docker-machine env ${NODE_PREFIX}${i})

	docker swarm join \
		--token ${TOKEN_MANAGER} \
		${DS_MGR_IP}:2377
done

for i in 4 5; do
	eval $(docker-machine env ${NODE_PREFIX}${i})

	docker swarm join \
		--token ${TOKEN_WOKER} \
		${DS_MGR_IP}:2377
done

# Add label to the cluster nodes
for i in {1..5}; do
	eval $(docker-machine env ${NODE_PREFIX}1)
	docker node update \
		--label-add env=prod \
		${NODE_PREFIX}${i}
done
}

cleanupAwsDockerswarmCluster(){
	echo "Cleaninig up Swarm Cluster: ${CLUSTERNAME}"

	for i in {1..5}; do
		docker-machine rm -f \
			${NODE_PREFIX}${i}
	done

	INSTANCE_STATUS=$(aws ec2 describe-instances --filters 'Name=tag:Name,Values='${NODE_PREFIX}'5'  --query  'Reservations[].Instances[].[State.Name]' --output text)
    
	until [[ ${INSTANCE_STATUS} == 'terminated' ]];
	do
		echo "Waiting for the instance termination ...";
		#echo ${INSTANCE_STATUS};
		sleep 3;
		INSTANCE_STATUS=$(aws ec2 describe-instances --filters 'Name=tag:Name,Values='${NODE_PREFIX}'5'  --query  'Reservations[].Instances[].[State.Name]' --output text)
	done

	#while true; do
	#	INSTANCE_STATUS=$(aws ec2 describe-instances --filters 'Name=tag:Name,Values='${NODE_PREFIX}'5'  --query  'Reservations[].Instances[].[State.Name]' --output text)
	#	if [[ ${INSTANCE_STATUS} == 'terminated' ]]; then
	#		break
	#	else
	#		echo "Waiting for the instance termination ...";
	#		echo ${INSTANCE_STATUS};
	#		sleep 10;
	#	fi
	#done

	echo "Cleaning AWS infrastructure ..."

	# Delete SG
	aws ec2 delete-security-group --group-id $(aws ec2 describe-security-groups --filter 'Name=group-name,Values='${CLUSTERNAME}'' --query 'SecurityGroups[].GroupId' --output text)

	# Delete Route
	aws ec2 delete-route --destination-cidr-block 0.0.0.0/0 --route-table-id $(aws ec2 describe-route-tables --filter 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'RouteTables[].RouteTableId' --output text)

	# Detach IGW
	aws ec2 detach-internet-gateway --internet-gateway-id $(aws ec2 describe-internet-gateways --filter 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'InternetGateways[].InternetGatewayId' --output text) --vpc-id $(aws ec2 describe-vpcs --filters 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'Vpcs[].VpcId' --output text)

	# Delete IGW
	aws ec2 delete-internet-gateway --internet-gateway-id $(aws ec2 describe-internet-gateways --filter 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'InternetGateways[].InternetGatewayId' --output text)

	# Disassociate RTB
	aws ec2 disassociate-route-table --association-id $(aws ec2 describe-route-tables --filters 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'RouteTables[].Associations[].RouteTableAssociationId' --output text)

	# Delete RTB
	aws ec2 delete-route-table --route-table-id  $(aws ec2 describe-route-tables --filters 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'RouteTables[].RouteTableId' --output text)

	# Delete subnet
	aws ec2 delete-subnet --subnet-id $(aws ec2 describe-subnets --filters 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'Subnets[].SubnetId' --output text)

	# Delete VPC
	aws ec2 delete-vpc --vpc-id  $(aws ec2 describe-vpcs --filters 'Name=tag:Name,Values='${CLUSTERNAME}'' --query 'Vpcs[].VpcId' --output text)
}


if [[ $# -lt 2 ]];  then
    echo "Please enter 'create / cleanup clustername'."
    exit 1
fi

CLUSTERNAME=$2
NODE_PREFIX=${CLUSTERNAME}-node

if [[ "$1" ==  "create" ]]; then
    createAwsDockerSwarmCluster

elif [[ "$1" == "cleanup" ]]; then
    cleanupAwsDockerswarmCluster

else
	echo "Something wrong."
	exit 2
fi
