#!/bin/bash

#example: from lib/testbridge, 
#./test.sh ./tests/echo/host ../../_build/install/default/bin/echo_host localhost:5000

if [ ! $# -eq 2 ] && [ ! $# -eq 3 ];
then
  echo "missing argument"
  exit 1
fi

if [ $# -eq 2 ]
then
  host=gcr.io/$(gcloud config get-value project)
else
  host=$3
fi

loc=$1
bin=$2

set -e

cd ../../
jbuilder build

cd lib/testbridge/$loc

../../../$bin \
  -container-count 2 \
  -containers-per-machine 2 \
  -image-host $host