#!/usr/bin/env bash
set -euo pipefail

# Run Terraform against a private EKS API endpoint reached through an SSM
# port-forward tunnel.
#
#   usage: scripts/tf-tunnel.sh plan -lock=false
#          scripts/tf-tunnel.sh apply
#
# Why this exists: the kubernetes and helm providers take an explicit host and
# would otherwise resolve module.eks.cluster_endpoint and dial the private
# endpoint directly. That fails with `dial tcp <private-ip>:443: i/o timeout`
# on any operation that actually contacts the cluster -- apply, import, or a
# plan WITH refresh. A `plan -refresh=false` does not contact the providers at
# all, so it succeeds either way and is not a valid check that this works.
#
# Arguments are passed to terraform verbatim. Per-experiment -var flags stay
# with the caller (scripts/deploy-storage-selection.sh owns its own set), so
# that an identical command means the same thing however it is invoked.

cd "$(dirname "$0")/.."

CLUSTER_NAME=${CLUSTER_NAME:-clickhouse-eks}
REGION=${AWS_REGION:-us-east-1}
TUNNEL_HOST=${TUNNEL_HOST:-127.0.0.1}
TUNNEL_PORT=${TUNNEL_PORT:-9444}
TUNNEL_URL="https://${TUNNEL_HOST}:${TUNNEL_PORT}"

if [ "$#" -eq 0 ]; then
  echo "ERROR: no terraform arguments given (e.g. plan, apply)." >&2
  exit 64
fi

aws_args=(--region "$REGION")
if [ -n "${AWS_PROFILE:-}" ]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

endpoint=$(aws eks describe-cluster "${aws_args[@]}" \
  --name "$CLUSTER_NAME" --query 'cluster.endpoint' --output text)
if [ -z "$endpoint" ] || [ "$endpoint" = "None" ]; then
  echo "ERROR: could not read the endpoint for cluster $CLUSTER_NAME." >&2
  exit 69
fi
# Strip scheme, then any port or path: SNI takes a bare hostname.
api_hostname=${endpoint#https://}
api_hostname=${api_hostname%%/*}
api_hostname=${api_hostname%%:*}

# Stage 1: something is listening. `-k` skips verification, so this alone does
# not prove the tunnel reaches the right cluster.
if ! curl -sk --max-time 8 -o /dev/null "$TUNNEL_URL/version"; then
  cat >&2 <<EOF
ERROR: no tunnel responding at $TUNNEL_URL

Start one with:
  aws ssm start-session --region $REGION --target <bastion-instance-id> \\
    --document-name AWS-StartPortForwardingSessionToRemoteHost \\
    --parameters '{"host":["$api_hostname"],"portNumber":["443"],"localPortNumber":["$TUNNEL_PORT"]}'
EOF
  exit 69
fi

# Stage 2: the certificate is valid for the real API hostname. Catches a tunnel
# pointed at the wrong cluster, which would otherwise surface as an opaque x509
# error from inside a provider call. 401/403 are healthy: TLS completed and the
# API server answered, we simply sent no credentials.
ca_file=$(mktemp)
trap 'rm -f "$ca_file"' EXIT
aws eks describe-cluster "${aws_args[@]}" --name "$CLUSTER_NAME" \
  --query 'cluster.certificateAuthority.data' --output text | base64 -d >"$ca_file"

tls_code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' \
  --cacert "$ca_file" \
  --resolve "${api_hostname}:${TUNNEL_PORT}:${TUNNEL_HOST}" \
  "https://${api_hostname}:${TUNNEL_PORT}/version" || true)
case "$tls_code" in
  200 | 401 | 403) ;;
  *)
    echo "ERROR: $TUNNEL_URL did not present a valid certificate for $api_hostname (got '$tls_code')." >&2
    echo "The tunnel may point at a different cluster." >&2
    exit 69
    ;;
esac

export TF_VAR_kube_api_endpoint_override="$TUNNEL_URL"
# providers.tf derives SNI from the cluster endpoint when this is empty; set it
# explicitly so the wrapper also works before that derivation is in place.
export TF_VAR_kube_api_tls_server_name="$api_hostname"

# Not required for the fix -- a tunneled plan/apply succeeds without it. Kept
# because HTTP/1.1 avoids HTTP/2 stream multiplexing over a single-stream
# forward. Note GODEBUG=http2client=0, which kubectl needs here, has no effect
# on these providers: client-go configures HTTP/2 through x/net/http2, which
# ignores that flag and reads DISABLE_HTTP2 instead.
export DISABLE_HTTP2=true

echo "==> terraform via $TUNNEL_URL (SNI $api_hostname)"
exec terraform -chdir=terraform "$@"
