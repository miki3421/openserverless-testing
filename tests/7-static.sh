#!/bin/bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TYPE="${1:?test type}"
TYPE="$(echo $TYPE | awk -F- '{print $1}')"

ops config enable --seaweedfs --static
ops update apply

ops util kube waitfor FOR=condition=ready OBJ=pod/openserverless-static-0 TIMEOUT=60
ops setup openserverless wait-cm-value \
    JSONPATH='{.metadata.annotations.s3_provider}' \
    EXPECTED_VALUE='seaweedfs' \
    MESSAGE='Waiting for SeaweedFS S3 provider'

user="demostaticuser"
password=$(ops -random --str 12)

ops admin deleteuser $user >/dev/null 2>&1 || true
if ops admin adduser $user $user@email.com $password --seaweedfs | grep "whiskuser.openserverless.org/$user created"; then
    echo SUCCESS CREATING $user
else
    echo FAIL CREATING $user
    exit 1
fi

ops util kube waitfor FOR=condition=ready OBJ="wsku/$user" TIMEOUT=120

API_PROTOCOL=$(ops debug apihost | awk '/whisk API host/{print $4}' | awk -F[/:] '{print $1}')
API_DOMAIN=$(ops debug apihost | awk '/whisk API host/{print $4}' | awk -F[/:] '{print $4}')


if [ "$TYPE" = "osh" ]; then
    ops debug kube wait OBJECT=route.route.openshift.io/$user-static-route JSONPATH="{.status.ingress[0].host}"
elif [ "$TYPE" != "kind" ]; then
    ops debug kube wait OBJECT=ingress/$user-static-ingress JSONPATH="{.status.loadBalancer.ingress[0]}"
fi
# Kind exposes ingress through NodePort/host mappings; it need not publish a
# LoadBalancer address. The HTTP check below verifies that the route is usable.

# Use the exact default content distributed by the running operator. This also
# rejects a generic gateway/login/error HTML page returned with HTTP 200.
STATIC_CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$STATIC_CHECK_DIR"' EXIT
OPERATOR_POD=$(kubectl -n openserverless get pods -l name=openserverless-operator \
    -o jsonpath='{.items[0].metadata.name}')
if [ -z "$OPERATOR_POD" ]; then
    echo "FAIL STATIC: operator pod unavailable for the reference content"
    exit 1
fi
kubectl -n openserverless exec "$OPERATOR_POD" -- \
    cat /home/openserverless/deploy/content/index.html > "$STATIC_CHECK_DIR/expected.html"
if [ ! -s "$STATIC_CHECK_DIR/expected.html" ]; then
    echo "FAIL STATIC: reference landing page is empty"
    exit 1
fi
STATIC_URL="$API_PROTOCOL://$user.$API_DOMAIN/"
bash "$SCRIPT_DIR/static-http-check.sh" "$STATIC_URL" "$STATIC_CHECK_DIR/expected.html"
