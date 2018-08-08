# This script is meant to be stepped through procedurally.
# It sets up and tests a zip file that allows execution of R code with AWS Lambda.
# All code here is run in a local R session.
# Based on:
# - https://github.com/station-x/lambda-r-survival-stats
# - https://aws.amazon.com/blogs/compute/analyzing-genomics-data-at-scale-using-r-aws-lambda-and-amazon-api-gateway/

## install these if not already installed
# devtools::install_github("cloudyr/awspack")
# install.packages("ssh")

library(aws.ec2)
library(aws.s3)
library(ssh)

# must have the following environment variables set:
# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY
# AWS_DEFAULT_REGION

# s3 bucket the lambda zip file will be stored
s3_bucket <- "r-lambda-test-h"

# lambda-compatible Amazon Linux AMI amzn-ami-hvm-2017.03.1.20170812-x86_64-gp2
amis <- list(
  "ap-northeast-1" = "ami-4af5022c",     "eu-west-1" = "ami-ebd02392",
  "ap-northeast-2" = "ami-8663bae8",     "eu-west-2" = "ami-489f8e2c",
  "ap-south-1"     = "ami-d7abd1b8",     "sa-east-1" = "ami-d27203be",
  "ap-southeast-1" = "ami-fdb8229e",     "us-east-1" = "ami-4fffc834",
  "ap-southeast-2" = "ami-30041c53",     "us-east-2" = "ami-ea87a78f",
  "ca-central-1"   = "ami-5ac17f3e",     "us-west-1" = "ami-3a674d5a",
  "eu-central-1"   = "ami-657bd20a",     "us-west-2" = "ami-aa5ebdd2"
)

image <- amis[[Sys.getenv("AWS_DEFAULT_REGION")]]

## initial setup
##---------------------------------------------------------

# create keypair
kp <- create_keypair("r-lambda-setup")
pem <- tempfile(fileext=".pem")
cat(kp$keyMaterial, file = pem)
Sys.chmod(pem, mode = "400")

# create s3 bucket if it doesn't exist
if (!bucket_exists(s3_bucket))
  put_bucket(s3_bucket)

# TODO: get disposable vpc, subnet, security group to work
# # set up vpc, subnet, security group
# vpc <- create_vpc(cidr = "10.0.0.0/16")
# sn <- create_subnet(vpc$vpcId, cidr = "10.0.1.0/24")
# sg <- create_sgroup(
#   "r-lambda-setup-sg",
#   "Allow my IP",
#   vpc = vpc$vpcId
# )
# authorize_ingress(sg)

## set up instance to create lambda zip file
##---------------------------------------------------------

inst1 <- run_instances(
  image = image,
  type = "t2.medium",
  # sgroup = sg,
  # subnet = sn,
  sgroup = "sg-97be4bf2", # replace with manually-created security group
  subnet = "subnet-f4777580", # replace with manually-created subnet
  keypair = kp
)
Sys.sleep(10L) # wait for instance to boot

ip1 <- allocate_ip("vpc")
associate_ip(inst1, ip1)

# if you want to ssh manually to inspect, etc.
message(paste0("ssh ec2-user@", ip1$publicIp, " -i ", pem))

session1 <- ssh::ssh_connect(paste0("ec2-user@", ip1$publicIp), keyfile = pem)

ssh1 <- function(x) ssh::ssh_exec_wait(session1, x)

# set AWS keys, etc.
ssh1(paste("
  aws configure set aws_access_key_id", Sys.getenv("AWS_ACCESS_KEY_ID"), "
  aws configure set aws_secret_access_key", Sys.getenv("AWS_SECRET_ACCESS_KEY"), "
  aws configure set default.region ", Sys.getenv("AWS_DEFAULT_REGION")
))

# install system dependencies
ssh1("
  sudo yum -y update
  sudo yum -y upgrade
  sudo yum install -y python36-devel python36-pip python36-virtualenv blas lapack gcc gcc-c++ readline-devel libgfortran.x86_64 R.x86_64"
)

# you can insert code here to install additional R pacakges...
# (...)

# virtualenv
ssh1("
  virtualenv-3.6 ~/env && source ~/env/bin/activate

  # install rpy2
  pip3 install rpy2

  # create a directory called lambda for the package
  mkdir $HOME/lambda && cd $HOME/lambda

  # put things into place for zip
  # (ldd /usr/lib64/R/bin/exec/R) find shared libraries, and copy all of the ones that were not already on the box
  sudo rm /usr/lib64/R/lib/libRrefblas.so
  cp -r /usr/lib64/R/* $HOME/lambda/
  cp /usr/lib64/R/lib/libR.so $HOME/lambda/lib/libR.so
  cp /usr/lib64/libgomp.so.1 $HOME/lambda/lib/
  cp /usr/lib64/libgfortran.so.3 $HOME/lambda/lib/
  cp /usr/lib64/libquadmath.so.0 $HOME/lambda/lib/
  cp /usr/lib64/libblas.so.3 $HOME/lambda/lib/
  cp /usr/lib64/liblapack.so.3 $HOME/lambda/lib/
  cp /usr/lib64/libtre.so.5 $HOME/lambda/lib/

  # copy R executable to root of package
  cp $HOME/lambda/bin/exec/R $HOME/lambda

  # copy necessary Python stuff
  cp -r $VIRTUAL_ENV/lib64/python3.6/site-packages/* $HOME/lambda
  cp -r $VIRTUAL_ENV/lib/python3.6/site-packages/* $HOME/lambda
  cp -r $VIRTUAL_ENV/lib64/python3.6/dist-packages/* $HOME/lambda
  cp -r $VIRTUAL_ENV/lib/python3.6/dist-packages/* $HOME/lambda
")

# copy test lambda script
ssh1("cd $HOME/lambda; wget https://raw.githubusercontent.com/hafen/r-lambda-setup/master/test-scripts/handler.py")

# zip things up and copy to s3
ssh1(paste0("
  cd $HOME/lambda
  zip -r9 $HOME/lambda_r_test.zip *
  aws s3 cp $HOME/lambda_r_test.zip s3://", s3_bucket
))


## set up another instance to test the zip on
##---------------------------------------------------------

inst2 <- run_instances(
  image = image,
  type = "t2.micro",
  # sgroup = sg,
  # subnet = sn,
  sgroup = "sg-97be4bf2",
  subnet = "subnet-f4777580",
  keypair = kp
)
Sys.sleep(10L) # wait for instance to boot

ip2 <- allocate_ip("vpc")
associate_ip(inst2, ip2)

# if you want to ssh manually to inspect, etc.
message(paste0("ssh ec2-user@", ip2$publicIp, " -i ", pem))

session2 <- ssh::ssh_connect(paste0("ec2-user@", ip2$publicIp), keyfile = pem)

ssh2 <- function(x) ssh::ssh_exec_wait(session2, x)

# install python 3.6
ssh2("sudo yum install -y python36-devel")

# set AWS keys, etc.
ssh2(paste("
  aws configure set aws_access_key_id", Sys.getenv("AWS_ACCESS_KEY_ID"), "
  aws configure set aws_secret_access_key", Sys.getenv("AWS_SECRET_ACCESS_KEY"), "
  aws configure set default.region ", Sys.getenv("AWS_DEFAULT_REGION")
))

# unzip
ssh2(paste0("
  aws s3 cp s3://", s3_bucket, "/lambda_r_test.zip .
  unzip lambda_r_test.zip
"))

# get test script
ssh2("wget https://raw.githubusercontent.com/hafen/r-lambda-setup/master/test-scripts/test_handler.py")

# test it out
ssh2("
  export R_HOME=$HOME
  export LD_LIBRARY_PATH=$HOME/lib
  python36 ./test_handler.py
")

# if nothing is returned then it worked correctly

## deploy... (TODO)
##---------------------------------------------------------

# https://aws.amazon.com/blogs/compute/extracting-video-metadata-using-lambda-and-mediainfo/
# (step 4)
# https://docs.aws.amazon.com/lambda/latest/dg/lambda-python-how-to-create-deployment-package.html
# https://docs.aws.amazon.com/apigateway/latest/developerguide/getting-started.html

## clean up
##---------------------------------------------------------

# stop and terminate instances
stop_instances(inst1)
terminate_instances(inst1)
stop_instances(inst2)
terminate_instances(inst2)

# delete keypair
delete_keypair(kp)

# release IP addresses
release_ip(ip1)
release_ip(ip2)
