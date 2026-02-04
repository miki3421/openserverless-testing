#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export OPS_BRANCH=main

usage() {
  echo "Usage: $0 '*.example.com'"
  echo "";
  echo "Input domain format: *.yourdomain"
}

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 1
fi

DOMAIN_RAW="$1"
APIHOST_INPUT=""
HOST=""
BASE_DOMAIN=""

if [[ "$DOMAIN_RAW" =~ ^https?:// ]]; then
  APIHOST_INPUT="$DOMAIN_RAW"
  HOST="${DOMAIN_RAW#http://}"
  HOST="${HOST#https://}"
elif [[ "$DOMAIN_RAW" == \*.* ]]; then
  BASE_DOMAIN="${DOMAIN_RAW#*.}"
  HOST="api.${BASE_DOMAIN}"
  APIHOST_INPUT="https://${HOST}"
else
  HOST="$DOMAIN_RAW"
  APIHOST_INPUT="https://${HOST}"
fi

if [ -z "$BASE_DOMAIN" ]; then
  if [[ "$HOST" == api.* ]]; then
    BASE_DOMAIN="${HOST#api.}"
  else
    BASE_DOMAIN="$HOST"
  fi
fi

if ! [[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || ! [[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Invalid domain: $DOMAIN_RAW"
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    return 1
  fi
}

missing=0
need_cmd kubectl || missing=1
need_cmd ops || missing=1
need_cmd curl || missing=1
HAS_RG=0
if command -v rg >/dev/null 2>&1; then
  HAS_RG=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

CONFIG_STATUS="$(ops config status 2>/dev/null || true)"

match_q() {
  if [ "$HAS_RG" -eq 1 ]; then
    rg -F -q "$1"
  else
    grep -F -q "$1"
  fi
}

tcp_check() {
  local host="$1"
  local port="$2"
  (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

parse_host_port() {
  local url="$1"
  local no_scheme="${url#http://}"
  no_scheme="${no_scheme#https://}"
  no_scheme="${no_scheme%%/*}"
  local host="${no_scheme%%:*}"
  local port="${no_scheme##*:}"
  if [ "$host" = "$port" ]; then
    port=""
  fi
  echo "$host" "$port"
}

ensure_k8s_connectivity() {
  local server
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [ -z "$server" ]; then
    echo "Warning: unable to read Kubernetes server from kubeconfig."
    return 1
  fi

  local host port
  read -r host port < <(parse_host_port "$server")
  if [ -z "$port" ]; then
    port=443
  fi

  if tcp_check "$host" "$port"; then
    echo "Kubernetes API reachable: $host:$port"
    return 0
  fi

  if [ "$host" = "127.0.0.1" ] || [ "$host" = "localhost" ]; then
    if [ -z "${SSH_TUNNEL_HOST:-}" ]; then
      echo "Kubernetes API not reachable on $host:$port."
      echo "Set SSH_TUNNEL_HOST (and optionally SSH_TUNNEL_USER, SSH_TUNNEL_KEY) to create a tunnel."
      return 1
    fi

    local ssh_target="$SSH_TUNNEL_HOST"
    if [ -n "${SSH_TUNNEL_USER:-}" ]; then
      ssh_target="${SSH_TUNNEL_USER}@${SSH_TUNNEL_HOST}"
    fi

    local ssh_opts=("-o" "ExitOnForwardFailure=yes")
    if [ -n "${SSH_TUNNEL_KEY:-}" ]; then
      ssh_opts+=("-i" "$SSH_TUNNEL_KEY")
    fi

    echo "Opening SSH tunnel for Kubernetes API: localhost:${port} -> ${SSH_TUNNEL_HOST}:${port}"
    ssh -f -N -L "${port}:localhost:${port}" "${ssh_opts[@]}" "$ssh_target" || return 1

    if tcp_check "$host" "$port"; then
      echo "SSH tunnel established for Kubernetes API."
      return 0
    fi
  fi

  echo "Kubernetes API not reachable: $host:$port"
  return 1
}

ensure_apihost_connectivity() {
  local host port
  read -r host port < <(parse_host_port "$APIHOST_INPUT")
  if [ -z "$port" ]; then
    port=443
  fi
  if tcp_check "$host" "$port"; then
    echo "API host reachable: $host:$port"
    return 0
  fi
  echo "API host not reachable: $host:$port"
  return 1
}

config_has_key() {
  if [ -z "$CONFIG_STATUS" ]; then
    return 1
  fi
  echo "$CONFIG_STATUS" | match_q "OPERATOR_COMPONENT_${1}="
}

config_enabled() {
  if [ -z "$CONFIG_STATUS" ]; then
    return 0
  fi
  echo "$CONFIG_STATUS" | match_q "OPERATOR_COMPONENT_${1}=true"
}

get_cm() {
  kubectl -n nuvolaris get cm/config -o jsonpath="$1" 2>/dev/null
}

get_ctrl() {
  kubectl -n nuvolaris get wsk/controller -o jsonpath="$1" 2>/dev/null
}

APIHOST_CM="$(get_cm '{.metadata.annotations.apihost}')"
if [ -z "$APIHOST_CM" ]; then
  echo "Unable to read apihost from cluster config. Is nuvolaris installed?"
  exit 1
fi

ADMIN_AUTH="$(get_ctrl '{.spec.openwhisk.namespaces.nuvolaris}')"
ADMIN_PASS="$(get_ctrl '{.spec.nuvolaris.password}')"
if [ -z "$ADMIN_AUTH" ] || [ -z "$ADMIN_PASS" ]; then
  echo "Unable to read admin credentials from wsk/controller."
  exit 1
fi

ADMIN_USER="nuvolaris"

if [ -n "$CONFIG_STATUS" ]; then
  echo "ops config status detected. Tests will be aligned to enabled components."
else
  echo "Warning: unable to read ops config status. Tests will run best-effort."
fi

if [ "${OPS_TEST_VERBOSE:-0}" = "1" ]; then
  if ops setup nuvolaris status >/dev/null 2>&1; then
    echo "ops setup nuvolaris status:"
    ops setup nuvolaris status || true
  fi
fi

ensure_apihost_connectivity || true
ensure_k8s_connectivity || true

wsk_admin() {
  ops -wsk --apihost "$APIHOST_CM" --auth "$ADMIN_AUTH" "$@"
}

login_user() {
  local user="$1"
  local pass="$2"
  OPS_PASSWORD="$pass" ops -login "$APIHOST_CM" "$user" >/dev/null
}

status_symbol() {
  case "$1" in
    0) echo "✅";;
    2) echo "N/A";;
    *) echo "❌";;
  esac
}

run_test() {
  local name="$1"
  shift
  echo "==> Running test: $name"
  local log="/tmp/ops-test-${name// /_}.log"
  "$@" 2>&1 | tee "$log"
  local status="${PIPESTATUS[0]}"
  if [ "$status" -eq 0 ]; then
    TEST_STATUS["$name"]=0
  else
    if [ "$status" -eq 2 ]; then
      TEST_STATUS["$name"]=2
    else
      TEST_STATUS["$name"]=1
    fi
    echo "Test failed: $name. Last output:"
    tail -n 20 "$log" || true
  fi
}

check_deploy() {
  kubectl -n nuvolaris get pods >/dev/null 2>&1
}

check_ssl() {
  curl -sS "$APIHOST_INPUT" >/dev/null 2>&1
}

check_sys_redis() {
  if config_has_key REDIS && ! config_enabled REDIS; then
    return 2
  fi
  local redis_url
  redis_url="$(get_cm '{.metadata.annotations.redis_url}')"
  local redis_prefix
  redis_prefix="$(get_cm '{.metadata.annotations.redis_prefix}')"
  if [ -z "$redis_url" ] || [ -z "$redis_prefix" ]; then
    return 2
  fi
  wsk_admin package update hello >/dev/null
  wsk_admin action update hello/redis "$SCRIPT_DIR/actions/redis.js" \
    -p redis_url "$redis_url" -p redis_prefix "$redis_prefix" >/dev/null
  wsk_admin action invoke hello/redis -r | match_q hello
}

check_sys_mongodb() {
  if config_has_key MONGODB && ! config_enabled MONGODB; then
    return 2
  fi
  local mongodb_url
  mongodb_url="$(get_cm '{.metadata.annotations.mongodb_url}')"
  if [ -z "$mongodb_url" ]; then
    return 2
  fi
  wsk_admin package update hello >/dev/null
  wsk_admin action update hello/mongodb "$SCRIPT_DIR/actions/mongodb.js" \
    -p mongodb_url "$mongodb_url" >/dev/null
  wsk_admin action invoke hello/mongodb -r | match_q hello
}

check_sys_postgres() {
  if config_has_key POSTGRES && ! config_enabled POSTGRES; then
    return 2
  fi
  local postgres_url
  postgres_url="$(get_cm '{.metadata.annotations.postgres_url}')"
  if [ -z "$postgres_url" ]; then
    return 2
  fi
  wsk_admin package update hello >/dev/null
  wsk_admin action update hello/postgres "$SCRIPT_DIR/actions/postgres.js" \
    -p dburi "$postgres_url" >/dev/null
  wsk_admin action invoke hello/postgres -r | match_q 'Nuvolaris Postgres is up and running!'
}

check_sys_minio() {
  if config_has_key MINIO && ! config_enabled MINIO; then
    return 2
  fi
  local s3_access
  local s3_secret
  local s3_host
  local s3_port
  local s3_bucket
  s3_access="$(get_cm '{.metadata.annotations.s3_access_key}')"
  s3_secret="$(get_cm '{.metadata.annotations.s3_secret_key}')"
  s3_host="$(get_cm '{.metadata.annotations.s3_host}')"
  s3_port="$(get_cm '{.metadata.annotations.s3_port}')"
  s3_bucket="$(get_cm '{.metadata.annotations.s3_bucket_data}')"
  if [ -z "$s3_access" ] || [ -z "$s3_secret" ] || [ -z "$s3_host" ] || [ -z "$s3_port" ] || [ -z "$s3_bucket" ]; then
    return 2
  fi
  wsk_admin package update hello >/dev/null
  wsk_admin action update hello/minio "$SCRIPT_DIR/actions/minio.js" \
    -p s3_access "$s3_access" \
    -p s3_secret "$s3_secret" \
    -p s3_host "$s3_host" \
    -p s3_port "$s3_port" \
    -p s3_data "$s3_bucket" >/dev/null
  wsk_admin action invoke hello/minio -r | match_q "$s3_bucket"
}

check_static_backend() {
  if config_has_key STATIC && ! config_enabled STATIC; then
    return 2
  fi
  if kubectl -n nuvolaris get svc/nuvolaris-static-svc >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_pods_for_enabled_components() {
  local missing=0
  local pods
  pods="$(kubectl -n nuvolaris get pods --no-headers 2>/dev/null || true)"

  require_pod() {
    local name="$1"
    local pattern="$2"
    if ! echo "$pods" | rg -q "$pattern"; then
      echo "Missing pod for ${name}: ${pattern}"
      missing=1
    fi
  }

  require_pod "operator" "^nuvolaris-operator-"
  require_pod "controller" "^controller-"

  if config_enabled REDIS; then
    require_pod "redis" "^redis-"
  fi
  if config_enabled MONGODB; then
    require_pod "mongodb" "^nuvolaris-mongodb-"
  fi
  if config_enabled POSTGRES; then
    require_pod "postgres" "^nuvolaris-postgres-"
  fi
  if config_enabled ETCD; then
    require_pod "etcd" "^nuvolaris-etcd-"
  fi
  if config_enabled REGISTRY; then
    require_pod "registry" "^registry-"
  fi
  if config_enabled SEAWEEDFS; then
    require_pod "seaweedfs" "^seaweedfs-"
  fi
  if config_enabled MILVUS; then
    require_pod "milvus" "^nuvolaris-milvus-"
  fi
  if config_enabled STATIC; then
    require_pod "static" "^nuvolaris-static-"
  fi

  if [ "$missing" -ne 0 ]; then
    return 1
  fi
  return 0
}

check_seaweedfs() {
  if [ -z "$BASE_DOMAIN" ]; then
    return 2
  fi
  local s3_host="s3.${BASE_DOMAIN}"
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" "https://${s3_host}" || true)"
  if [ "$code" = "000" ] || [ -z "$code" ]; then
    return 1
  fi
  return 0
}

create_user() {
  local user="$1"
  local pass="$2"
  shift 2
  if ops admin adduser "$user" "$user@email.com" "$pass" "$@" 2>&1 | tee /tmp/ops-adduser.log | match_q "whiskuser.nuvolaris.org/$user created"; then
    kubectl -n nuvolaris wait --for=condition=ready "wsku/$user" --timeout=120s >/dev/null 2>&1
    return 0
  fi
  echo "adduser failed for $user. Last output:"
  tail -n 20 /tmp/ops-adduser.log || true
  return 1
}

rand_suffix() {
  tr -dc 'a-z' </dev/urandom | head -c 6
}

check_login() {
  local user="demouser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  local flags=()
  if [ -n "$(get_cm '{.metadata.annotations.redis_url}')" ]; then
    flags+=("--redis")
  fi
  if [ -n "$(get_cm '{.metadata.annotations.mongodb_url}')" ]; then
    flags+=("--mongodb")
  fi
  if config_has_key MINIO && ! config_enabled MINIO; then
    :
  elif [ -n "$(get_cm '{.metadata.annotations.s3_access_key}')" ]; then
    flags+=("--minio")
  fi
  if [ -n "$(get_cm '{.metadata.annotations.postgres_url}')" ]; then
    flags+=("--postgres")
  fi

  create_user "$user" "$pass" "${flags[@]}" || return 1
  login_user "$user" "$pass" || return 1

  ops -wsk package update hello >/dev/null
  ops -wsk action update hello/hello "$SCRIPT_DIR/actions/hello.js" >/dev/null
  ops -wsk action invoke hello/hello -p name "Apache OpenServerless" -r | match_q hello
}

check_static() {
  if config_has_key STATIC && ! config_enabled STATIC; then
    return 2
  fi
  if config_has_key MINIO && ! config_enabled MINIO; then
    return 2
  fi
  local bucket_static
  bucket_static="$(get_cm '{.metadata.annotations.s3_bucket_static}')"
  if [ -z "$bucket_static" ]; then
    return 2
  fi

  local user="demostaticuser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  create_user "$user" "$pass" --minio || return 1

  local static_url="https://${user}.${BASE_DOMAIN}"
  local n=0
  while [ "$n" -lt 12 ]; do
    if curl -fsS "$static_url" | match_q "static content distributor landing page"; then
      return 0
    fi
    n=$((n + 1))
    sleep 5
  done
  return 1
}

check_user_redis() {
  if config_has_key REDIS && ! config_enabled REDIS; then
    return 2
  fi
  local redis_url
  local redis_prefix

  local user="demoredisuser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  create_user "$user" "$pass" --redis || return 1
  login_user "$user" "$pass" || return 1

  redis_url="$(ops -config REDIS_URL)"
  redis_prefix="$(ops -config REDIS_PREFIX)"
  if [ -z "$redis_url" ] || [ -z "$redis_prefix" ]; then
    return 2
  fi

  ops -wsk package update hello >/dev/null
  ops -wsk action update hello/redis "$SCRIPT_DIR/actions/redis.js" \
    -p redis_url "$redis_url" -p redis_prefix "$redis_prefix" >/dev/null
  ops -wsk action invoke hello/redis -r | match_q hello
}

check_user_mongodb() {
  if config_has_key MONGODB && ! config_enabled MONGODB; then
    return 2
  fi
  local mongodb_url

  local user="demomongouser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  create_user "$user" "$pass" --mongodb || return 1
  login_user "$user" "$pass" || return 1

  mongodb_url="$(ops -config MONGODB_URL)"
  if [ -z "$mongodb_url" ]; then
    return 2
  fi

  ops -wsk package update hello >/dev/null
  ops -wsk action update hello/mongodb "$SCRIPT_DIR/actions/mongodb.js" \
    -p mongodb_url "$mongodb_url" >/dev/null
  ops -wsk action invoke hello/mongodb -r | match_q hello
}

check_user_postgres() {
  if config_has_key POSTGRES && ! config_enabled POSTGRES; then
    return 2
  fi
  local postgres_url

  local user="demopguser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  create_user "$user" "$pass" --postgres || return 1
  login_user "$user" "$pass" || return 1

  postgres_url="$(ops -config POSTGRES_URL)"
  if [ -z "$postgres_url" ]; then
    return 2
  fi

  ops -wsk package update hello >/dev/null
  ops -wsk action update hello/postgres "$SCRIPT_DIR/actions/postgres.js" \
    -p dburi "$postgres_url" >/dev/null
  ops -wsk action invoke hello/postgres -r | match_q 'Nuvolaris Postgres is up and running!'
}

check_user_minio() {
  if config_has_key MINIO && ! config_enabled MINIO; then
    return 2
  fi
  local s3_access
  local s3_secret
  local s3_host
  local s3_port
  local s3_bucket

  local user="demominiouser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  create_user "$user" "$pass" --minio || return 1
  login_user "$user" "$pass" || return 1

  s3_access="$(ops -config S3_ACCESS_KEY)"
  s3_secret="$(ops -config S3_SECRET_KEY)"
  s3_host="$(ops -config S3_HOST)"
  s3_port="$(ops -config S3_PORT)"
  s3_bucket="$(ops -config S3_BUCKET_DATA)"
  if [ -z "$s3_access" ] || [ -z "$s3_secret" ] || [ -z "$s3_host" ] || [ -z "$s3_port" ] || [ -z "$s3_bucket" ]; then
    return 2
  fi

  ops -wsk package update hello >/dev/null
  ops -wsk action update hello/minio "$SCRIPT_DIR/actions/minio.js" \
    -p s3_access "$s3_access" \
    -p s3_secret "$s3_secret" \
    -p s3_host "$s3_host" \
    -p s3_port "$s3_port" \
    -p s3_data "$s3_bucket" >/dev/null
  ops -wsk action invoke hello/minio -r | match_q "$s3_bucket"
}

check_nuv_win() {
  return 2
}

check_nuv_mac() {
  return 2
}

check_runtimes() {
  if config_has_key MINIO && ! config_enabled MINIO; then
    return 2
  fi
  if config_has_key REDIS && ! config_enabled REDIS; then
    return 2
  fi
  if config_has_key MONGODB && ! config_enabled MONGODB; then
    return 2
  fi
  if config_has_key POSTGRES && ! config_enabled POSTGRES; then
    return 2
  fi
  local user="testactionuser$(rand_suffix)"
  local pass
  pass="$(ops -random --str 12)"

  create_user "$user" "$pass" --minio --redis --mongodb --postgres || return 1
  login_user "$user" "$pass" || return 1

  export S3_ACCESS_KEY
  export S3_SECRET_KEY
  export S3_HOST
  export S3_PORT
  export S3_BUCKET_DATA
  export S3_BUCKET_STATIC
  export REDIS_URL
  export REDIS_PREFIX
  export MONGODB_URL
  export MONGODB_DB="$user"
  export POSTGRES_URL

  S3_ACCESS_KEY="$(ops -config S3_ACCESS_KEY)"
  S3_SECRET_KEY="$(ops -config S3_SECRET_KEY)"
  S3_HOST="$(ops -config S3_HOST)"
  S3_PORT="$(ops -config S3_PORT)"
  S3_BUCKET_DATA="$(ops -config S3_BUCKET_DATA)"
  S3_BUCKET_STATIC="$(ops -config S3_BUCKET_STATIC)"
  REDIS_URL="$(ops -config REDIS_URL)"
  REDIS_PREFIX="$(ops -config REDIS_PREFIX)"
  MONGODB_URL="$(ops -config MONGODB_URL)"
  POSTGRES_URL="$(ops -config POSTGRES_URL)"

  if [ -z "$S3_ACCESS_KEY" ] || [ -z "$REDIS_URL" ] || [ -z "$MONGODB_URL" ] || [ -z "$POSTGRES_URL" ]; then
    return 2
  fi

  ( cd "$SCRIPT_DIR/runtimes" && ops -wsk project deploy --manifest manifest.yaml >/dev/null )

  ops -wsk action invoke javascript/hello -r | match_q world || return 1
  ops -wsk action invoke javascript/redis -r | match_q hello || return 1
  ops -wsk action invoke javascript/mongodb -r | match_q hello || return 1
  ops -wsk action invoke javascript/postgres -r | match_q 'Nuvolaris Postgres is up and running!' || return 1
  ops -wsk action invoke javascript/minio -r | match_q "$user-data" || return 1

  ops -wsk action invoke python/hello -r | match_q world || return 1
  ops -wsk action invoke python/redis -r | match_q world || return 1
  ops -wsk action invoke python/mongodb -r | match_q world || return 1
  ops -wsk action invoke python/postgres -r | match_q 'Nuvolaris Postgres is up and running!' || return 1
  ops -wsk action invoke python/minio -r | match_q "$user-data"
}

declare -A TEST_STATUS

run_test "Deploy" check_deploy
run_test "SSL" check_ssl
run_test "Sys Redis" check_sys_redis
run_test "Sys FerretDB" check_sys_mongodb
run_test "Sys Postgres" check_sys_postgres
run_test "Sys Minio" check_sys_minio
run_test "SeaweedFS" check_seaweedfs
run_test "Static Backend" check_static_backend
run_test "Core Pods" check_pods_for_enabled_components
run_test "Login" check_login
run_test "Statics" check_static
run_test "User Redis" check_user_redis
run_test "User FerretDB" check_user_mongodb
run_test "User Postgres" check_user_postgres
run_test "User Minio" check_user_minio
run_test "Nuv Win" check_nuv_win
run_test "Nuv Mac" check_nuv_mac
run_test "Runtimes" check_runtimes

K3S_DEPLOY="$(status_symbol "${TEST_STATUS[Deploy]:-1}")"
K3S_SSL="$(status_symbol "${TEST_STATUS[SSL]:-1}")"
K3S_SYS_REDIS="$(status_symbol "${TEST_STATUS[Sys Redis]:-1}")"
K3S_SYS_FERRET="$(status_symbol "${TEST_STATUS[Sys FerretDB]:-1}")"
K3S_SYS_PG="$(status_symbol "${TEST_STATUS[Sys Postgres]:-1}")"
K3S_SYS_MINIO="$(status_symbol "${TEST_STATUS[Sys Minio]:-1}")"
K3S_SEAWEEDFS="$(status_symbol "${TEST_STATUS[SeaweedFS]:-1}")"
K3S_STATIC_BACKEND="$(status_symbol "${TEST_STATUS[Static Backend]:-1}")"
K3S_CORE_PODS="$(status_symbol "${TEST_STATUS[Core Pods]:-1}")"
K3S_LOGIN="$(status_symbol "${TEST_STATUS[Login]:-1}")"
K3S_STATIC="$(status_symbol "${TEST_STATUS[Statics]:-1}")"
K3S_USER_REDIS="$(status_symbol "${TEST_STATUS[User Redis]:-1}")"
K3S_USER_FERRET="$(status_symbol "${TEST_STATUS[User FerretDB]:-1}")"
K3S_USER_PG="$(status_symbol "${TEST_STATUS[User Postgres]:-1}")"
K3S_USER_MINIO="$(status_symbol "${TEST_STATUS[User Minio]:-1}")"
K3S_NUV_WIN="$(status_symbol "${TEST_STATUS[Nuv Win]:-1}")"
K3S_NUV_MAC="$(status_symbol "${TEST_STATUS[Nuv Mac]:-1}")"
K3S_RUNTIMES="$(status_symbol "${TEST_STATUS[Runtimes]:-1}")"

cat <<TABLE

|  |               |K3S |
|--|---------------|----|
|1 |Deploy         | $K3S_DEPLOY |
|2 |SSL            | $K3S_SSL |
|3 |Sys Redis      | $K3S_SYS_REDIS |
|4a|Sys FerretDB   | $K3S_SYS_FERRET |
|4b|Sys Postgres   | $K3S_SYS_PG |
|5 |Sys Minio      | $K3S_SYS_MINIO |
|6 |SeaweedFS      | $K3S_SEAWEEDFS |
|7 |Static Backend | $K3S_STATIC_BACKEND |
|8 |Core Pods      | $K3S_CORE_PODS |
|9 |Login          | $K3S_LOGIN |
|10|Statics        | $K3S_STATIC |
|11|User Redis     | $K3S_USER_REDIS |
|12|User FerretDB  | $K3S_USER_FERRET |
|13|User Postgres  | $K3S_USER_PG |
|14|User Minio     | $K3S_USER_MINIO |
|15|Nuv Win        | $K3S_NUV_WIN |
|16|Nuv Mac        | $K3S_NUV_MAC |
|17|Runtimes       | $K3S_RUNTIMES |
TABLE

if [ "$APIHOST_CM" != "$APIHOST_INPUT" ]; then
  echo
  echo "Note: cluster apihost is $APIHOST_CM (input was $APIHOST_INPUT)."
fi
