#!/bin/bash

`aws ecr get-login --region us-east-1` && \
docker build -t cbusdcad-trader . && \
docker tag cbusdcad-trader:latest 248022314417.dkr.ecr.us-east-1.amazonaws.com/cbusdcad-trader:latest && \
docker push 248022314417.dkr.ecr.us-east-1.amazonaws.com/cbusdcad-trader:latest
