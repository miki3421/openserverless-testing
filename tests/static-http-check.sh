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
# Verify transport success and byte-exact content without logging response bodies.
set -euo pipefail
STATIC_URL="${1:?static URL}"
STATIC_EXPECTED="${2:?reference content file}"
STATIC_ATTEMPTS="${3:-12}"
STATIC_DELAY="${4:-5}"
case "$STATIC_URL" in http://*|https://*) ;; *) echo "FAIL STATIC: invalid URL"; exit 2 ;; esac
if [[ ! "$STATIC_ATTEMPTS" =~ ^[0-9]+$ ]] || (( STATIC_ATTEMPTS < 1 || STATIC_ATTEMPTS > 60 )) ||
   [[ ! "$STATIC_DELAY" =~ ^[0-9]+$ ]] || (( STATIC_DELAY > 30 )) || [ ! -s "$STATIC_EXPECTED" ]; then
    echo "FAIL STATIC: invalid reference or retry configuration"
    exit 2
fi
STATIC_ACTUAL=$(mktemp)
trap 'rm -f "$STATIC_ACTUAL"' EXIT
for (( STATIC_TRY=1; STATIC_TRY<=STATIC_ATTEMPTS; STATIC_TRY++ )); do
    if curl --fail --silent --show-error --max-time 10 --output "$STATIC_ACTUAL" "$STATIC_URL" 2>/dev/null &&
       cmp -s "$STATIC_EXPECTED" "$STATIC_ACTUAL"; then
        echo "SUCCESS STATIC: HTTP success and exact landing-page content"
        exit 0
    fi
    if (( STATIC_TRY < STATIC_ATTEMPTS )); then sleep "$STATIC_DELAY"; fi
done
echo "FAIL STATIC: HTTP request or landing-page content mismatch"
exit 1
