#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -x

WORKPATH=$(dirname "$PWD")
ip_address=$(hostname -I | awk '{print $1}')
LOG_PATH="$WORKPATH/tests"

function build_docker_images() {
    cd $WORKPATH
    docker build --no-cache -t opea/llm-sum-tgi:comps --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f comps/llms/summarization/tgi/langchain/Dockerfile .
    if [ $? -ne 0 ]; then
        echo "opea/llm-tgi built fail"
        exit 1
    else
        echo "opea/llm-tgi built successful"
    fi
}

function start_service() {
    tgi_endpoint_port=5075
    export your_hf_llm_model="Intel/neural-chat-7b-v3-3"
    # Remember to set HF_TOKEN before invoking this test!
    export HF_TOKEN=${HF_TOKEN}
    docker run -d --name="test-comps-llm-sum-tgi-endpoint" -p $tgi_endpoint_port:80 -v ./data:/data -e http_proxy=$http_proxy -e https_proxy=$https_proxy --shm-size 1g ghcr.io/huggingface/text-generation-inference:1.4 --model-id ${your_hf_llm_model}
    export TGI_LLM_ENDPOINT="http://${ip_address}:${tgi_endpoint_port}"

    sum_port=5076
    docker run -d --name="test-comps-llm-sum-tgi-server" -p ${sum_port}:9000 --ipc=host -e http_proxy=$http_proxy -e https_proxy=$https_proxy -e TGI_LLM_ENDPOINT=$TGI_LLM_ENDPOINT -e HUGGINGFACEHUB_API_TOKEN=$HF_TOKEN opea/llm-sum-tgi:comps

    # check whether tgi is fully ready
    n=0
    until [[ "$n" -ge 100 ]] || [[ $ready == true ]]; do
        docker logs test-comps-llm-sum-tgi-endpoint > ${LOG_PATH}/test-comps-llm-sum-tgi-endpoint.log
        n=$((n+1))
        if grep -q Connected ${LOG_PATH}/test-comps-llm-sum-tgi-endpoint.log; then
            break
        fi
        sleep 5s
    done
    sleep 5s
}

function validate_microservice() {
    sum_port=5076
    http_proxy="" curl http://${ip_address}:${sum_port}/v1/chat/docsum \
        -X POST \
        -d '{"query":"Deep learning is a subset of machine learning that utilizes neural networks with multiple layers to analyze various levels of abstract data representations. It enables computers to identify patterns and make decisions with minimal human intervention by learning from large amounts of data."}' \
        -H 'Content-Type: application/json'
    docker logs test-comps-llm-sum-tgi-endpoint
    docker logs test-comps-llm-sum-tgi-server

    URL="http://${ip_address}:$sum_port/v1/chat/docsum"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d '{"query": "What is Deep Learning?"}' -H 'Content-Type: application/json' "$URL")
    if [ "$HTTP_STATUS" -eq 200 ]; then
        echo "[ llm - summarization ] HTTP status is 200. Checking content..."
        local CONTENT=$(curl -s -X POST -d '{"query": "What is Deep Learning?"}' -H 'Content-Type: application/json' "$URL" | tee ${LOG_PATH}/llm_summarization.log)

        if echo 'text: ' | grep -q "$EXPECTED_RESULT"; then
            echo "[ llm - summarization ] Content is as expected."
            docker logs test-comps-llm-sum-tgi-server >> ${LOG_PATH}/llm_summarization.log
        else
            echo "[ llm - summarization ] Content does not match the expected result: $CONTENT"
            docker logs test-comps-llm-sum-tgi-server >> ${LOG_PATH}/llm_summarization.log
            exit 1
        fi
    else
        echo "[ llm - summarization ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs test-comps-llm-sum-tgi-server >> ${LOG_PATH}/llm_summarization.log
        exit 1
    fi
}

function stop_docker() {
    cid=$(docker ps -aq --filter "name=test-comps-llm-sum-tgi*")
    if [[ ! -z "$cid" ]]; then docker stop $cid && docker rm $cid && sleep 1s; fi
}

function main() {

    stop_docker

    build_docker_images
    start_service

    validate_microservice

    stop_docker
    echo y | docker system prune

}

main
