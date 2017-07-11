#!/usr/bin/env bash

# Copyright 2017 Tadaweb S.A. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cluster_name=rabbit0
if [[ ! -z $CLUSTER_NAME ]]; then
    cluster_name=$CLUSTER_NAME
fi

node_name=rabbit
if [[ ! -z $RABBITMQ_NODENAME ]]; then
    node_name=$RABBITMQ_NODENAME
fi

script_name=${0##*/}

function log() {
    local msg="$1"
    local timestamp="$(date --iso-8607=ns)"
    echo "[$timestamp] rabbitmq_init $msg" >> /install/bootstrap.log
}


container_hostname=$(hostname)

peers=()
while read -ra line; do
    if [[ "$line" != *"${container_hostname}"* ]]; then
        peers=("${peers[@]}" "$line")
    else
        rabbitmq_instance=$line
    fi
done

log "Found peers ${peers[@]}"
log "Rabbitmq instance: $rabbitmq_instance"

log "Running Rabbitmq script..."
/docker-entrypoint.sh rabbitmq-server &

log "Wait for the rabbitmq node to be up. Fetching node health check..."
until rabbitmqctl node_health_check; do
    sleep 2
done

log "Collect rabbitmq cluster list."
cluster_members=($(rabbitmqctl cluster_status | sed -e '1d' -e 's/ //g' | tr -d '\n' | cut -d'[' -f4 | cut -d']' -f1 | sed -e "s/'//g" -e "s/,/ /g"))
log "Rabbitmq current cluster members: ${cluster_members[@]}"

if [[ ${#cluster_members[@]} -gt 1 ]]; then
    log "Rabbitmq cluster is already initialized and contains ${#cluster_members[@]} members: ${cluster_members[@]}"
    log "Shutting down rabbitmq instance..."
    rabbitmqctl stop
    log "Exit"
    exit 0
fi

biggest=0
biggest_name=""
# get the peer with the hugest number of members
log "Fetching the node with the greatest number of members"
for peer in "${peers[@]}"; do
    log "Get status from peer $node_name@$peer"
    rabbitmq_output=$(rabbitmqctl -n $node_name@$peer cluster_status)
    if [[ $? -ne 0 ]]; then
      continue
    fi
    peer_members=($(rabbitmqctl -n $node_name@$peer cluster_status | sed -e '1d' -e 's/ //g' | tr -d '\n' | cut -d'[' -f4 | cut -d']' -f1 | sed -e "s/'//g" -e "s/,/ /g"))
    log "Peer members for $peer --> ${peer_members[@]}"

    if [[ ${#peer_members[@]} -gt $biggest ]]; then
        log "The node $peer has a greater number of members than $biggest_name"
        biggest=${#peer_members[@]}
        biggest_name=$peer
    fi
done

if [[ biggest -ne 0 ]]; then
    log "Node $rabbitmq_instance join the cluster @ $biggest_name"
    rabbitmqctl stop_app
    rabbitmqctl join_cluster $node_name@$biggest_name
    rabbitmqctl start_app
else
    log "The node $rabbitmq_instance is the only one and is starting a cluster by itself"
    rabbitmqctl set_cluster_name $cluster_name
fi

log "Shutting down rabbitmq instance"
rabbitmqctl stop
log "Exit"
exit 0
