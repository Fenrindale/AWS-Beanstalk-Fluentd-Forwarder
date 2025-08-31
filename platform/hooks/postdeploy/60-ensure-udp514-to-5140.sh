#!/usr/bin/env bash
# Ensure NLB UDP :514 -> TG(UDP/5140, HC TCP/5140) and ASG attachment.
# - Idempotent
# - Uses IMDSv2
# - Verifies and fails (exit 1) if path isn't healthy to avoid silent data loss.
# - Minimal hardening for Immutable(temporary ASG) timing: robust VPC/LB discovery + guarded listener ops
#   Tunables via env: UDP514_STRICT_VERIFY(0|1), UDP514_VERIFY_MAX_SECS, UDP514_DISCOVER_MAX_SECS

set -u                      # intentionally no -e
LOG=/var/log/eb-hooks.log
exec 1>>"$LOG" 2>&1
echo "[udp514] ---- $(date -Is) START ----"

# ---------------- helpers ----------------
get_imds_token() {
  curl -sS -m 2 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds:21600' || true
}
imds() {  # imds <path>
  local tok; tok="$(get_imds_token)"
  curl -sS -m 2 -H "X-aws-ec2-metadata-token: ${tok}" \
    "http://169.254.169.254$1" || true
}
with_timeout() {  # with_timeout <sec> <cmd...>
  local sec="$1"; shift
  timeout "${sec}s" "$@"
}
retry() { # retry <tries> <sleep> <sec-timeout> <cmd...>
  local tries="$1" sleep_s="$2" to="$3"; shift 3
  local i
  for ((i=1;i<=tries;i++)); do
    if with_timeout "$to" "$@"; then return 0; fi
    sleep "$sleep_s"
  done
  return 1
}

# ---- env knobs (minimal additions) ----
[ -f /opt/elasticbeanstalk/deployment/env ] && . /opt/elasticbeanstalk/deployment/env || true
STRICT="${UDP514_STRICT_VERIFY:-1}"           # default: strict (exit 1 on verify fail)
VERIFY_MAX="${UDP514_VERIFY_MAX_SECS:-180}"   # total wait for health (seconds)
DISCOVER_MAX="${UDP514_DISCOVER_MAX_SECS:-300}" # max time to discover LB/VPC (seconds)

# ---------------- discover ----------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(imds /latest/dynamic/instance-identity/document | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')}}"
IID="${EC2_INSTANCE_ID:-$(imds /latest/meta-data/instance-id)}"
if [[ -z "$REGION" || -z "$IID" ]]; then
  echo "[udp514] ERROR: region or instance-id not found"; exit 1
fi
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

ASG_NAME="$(retry 5 3 20 aws autoscaling describe-auto-scaling-instances \
  --instance-ids "$IID" --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text || true)"
if [[ -z "$ASG_NAME" || "$ASG_NAME" == "None" ]]; then
  echo "[udp514] ERROR: ASG not found for instance $IID"; exit 1
fi

# --- Hardened discovery (covers Immutable timing) ---
# Try 3 routes to obtain LB ARNs + VPC. Always keep VPC from IMDS as fallback.
MAC="$(imds /latest/meta-data/network/interfaces/macs/ | head -n1 | tr -d '/')"
VPC_ID_IMDS="$(imds /latest/meta-data/network/interfaces/macs/${MAC}/vpc-id || true)"

PRIMARY_TG=""
LB_ARNS=""
VPC_ID=""
deadline=$(( $(date +%s) + DISCOVER_MAX ))

while [[ $(date +%s) -lt $deadline ]]; do
  # 1) ASG → LoadBalancerTargetGroups (original path)
  if [[ -z "$PRIMARY_TG" || "$PRIMARY_TG" == "None" ]]; then
    PRIMARY_TG="$(aws autoscaling describe-load-balancer-target-groups \
      --auto-scaling-group-name "$ASG_NAME" \
      --query 'LoadBalancerTargetGroups[0].LoadBalancerTargetGroupARN' --output text 2>/dev/null || true)"
  fi
  if [[ -n "$PRIMARY_TG" && "$PRIMARY_TG" != "None" ]]; then
    [[ -z "$LB_ARNS" || "$LB_ARNS" == "None" ]] && \
      LB_ARNS="$(aws elbv2 describe-target-groups --target-group-arns "$PRIMARY_TG" \
        --query 'TargetGroups[0].LoadBalancerArns' --output text 2>/dev/null || true)"
    [[ -z "$VPC_ID"   || "$VPC_ID"   == "None" ]] && \
      VPC_ID="$(aws elbv2 describe-target-groups --target-group-arns "$PRIMARY_TG" \
        --query 'TargetGroups[0].VpcId' --output text 2>/dev/null || true)"
  fi

  # 2) ASG → TargetGroupARNs (additional path)
  if [[ -z "$LB_ARNS" || "$LB_ARNS" == "None" ]]; then
    ANY_TG="$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].TargetGroupARNs[0]' --output text 2}/dev/null || true)"
    if [[ -n "$ANY_TG" && "$ANY_TG" != "None" ]]; then
      LB_ARNS="$(aws elbv2 describe-target-groups --target-group-arns "$ANY_TG" \
        --query 'TargetGroups[0].LoadBalancerArns' --output text 2>/dev/null || true)"
      [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && \
        VPC_ID="$(aws elbv2 describe-target-groups --target-group-arns "$ANY_TG" \
          --query 'TargetGroups[0].VpcId' --output text 2>/dev/null || true)"
    fi
  fi

  # 3) Reverse lookup: TGs that already contain this instance (last resort)
  if [[ -z "$LB_ARNS" || "$LB_ARNS" == "None" ]]; then
    TG_LIST="$(aws elbv2 describe-target-groups --query 'TargetGroups[?TargetType==`instance`].TargetGroupArn' --output text 2>/dev/null || true)"
    for TG in $TG_LIST; do
      hit="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
        --query "length(TargetHealthDescriptions[?Target.Id=='$IID'])" --output text 2>/dev/null || echo 0)"
      if [[ "$hit" == "1" ]]; then
        [[ -z "$LB_ARNS" || "$LB_ARNS" == "None" ]] && \
          LB_ARNS="$(aws elbv2 describe-target-groups --target-group-arns "$TG" \
            --query 'TargetGroups[0].LoadBalancerArns' --output text 2>/dev/null || true)"
        [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && \
          VPC_ID="$(aws elbv2 describe-target-groups --target-group-arns "$TG" \
            --query 'TargetGroups[0].VpcId' --output text 2>/dev/null || true)"
        break
      fi
    done
  fi

  # finalize or keep waiting
  [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && VPC_ID="$VPC_ID_IMDS"
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" && -n "$LB_ARNS" && "$LB_ARNS" != "None" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "[udp514] ERROR: VPC not discoverable"; exit 1
fi

SKIP_LISTENER=0
if [[ -z "$LB_ARNS" || "$LB_ARNS" == "None" ]]; then
  echo "[udp514] WARN: LB ARNs not discoverable yet; will skip listener ensure this run"
  SKIP_LISTENER=1
fi

# ---------------- ensure TG (UDP/5140, HC TCP/5140) ----------------
TG_NAME="tg-eb-udp-5140"
TG_ARN="$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  TG_ARN="$(retry 3 2 30 aws elbv2 create-target-group \
    --name "$TG_NAME" --protocol UDP --port 5140 --target-type instance \
    --vpc-id "$VPC_ID" --health-check-protocol TCP --health-check-port "5140" \
    --query 'TargetGroups[0].TargetGroupArn' --output text || true)"
fi
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  echo "[udp514] ERROR: could not create/lookup UDP TG"; exit 1
fi
echo "[udp514] TG_ARN=$TG_ARN"

# Attach TG to ASG (idempotent)
if ! aws autoscaling describe-load-balancer-target-groups \
     --auto-scaling-group-name "$ASG_NAME" \
     --query 'LoadBalancerTargetGroups[].LoadBalancerTargetGroupARN' --output text \
     | tr '\t' '\n' | grep -Fxq "$TG_ARN"; then
  retry 3 2 30 aws autoscaling attach-load-balancer-target-groups \
    --auto-scaling-group-name "$ASG_NAME" --target-group-arns "$TG_ARN" || {
      echo "[udp514] ERROR: attach TG to ASG failed"; exit 1; }
fi

# ---------------- ensure UDP :514 listener on each LB ----------------
if [[ "$SKIP_LISTENER" -eq 0 ]]; then
  for LB in $LB_ARNS; do
    CUR_LSN="$(aws elbv2 describe-listeners --load-balancer-arn "$LB" \
               --query "Listeners[?Protocol=='UDP' && Port==\`514\`].ListenerArn" --output text || true)"
    if [[ -z "$CUR_LSN" || "$CUR_LSN" == "None" ]]; then
      echo "[udp514] create UDP:514 listener on $LB"
      retry 3 2 30 aws elbv2 create-listener --load-balancer-arn "$LB" \
        --protocol UDP --port 514 \
        --default-actions Type=forward,TargetGroupArn="$TG_ARN" || {
          echo "[udp514] ERROR: create listener failed on $LB"; exit 1; }
    else
      CUR_TG="$(aws elbv2 describe-listeners --load-balancer-arn "$LB" \
               --query "Listeners[?ListenerArn=='$CUR_LSN'].DefaultActions[0].TargetGroupArn" \
               --output text || true)"
      if [[ "$CUR_TG" != "$TG_ARN" ]]; then
        echo "[udp514] modify UDP:514 listener -> our TG on $LB"
        retry 3 2 30 aws elbv2 modify-listener --listener-arn "$CUR_LSN" \
          --default-actions Type=forward,TargetGroupArn="$TG_ARN" || {
            echo "[udp514] ERROR: modify listener failed on $LB"; exit 1; }
      fi
    fi
  done
else
  echo "[udp514] SKIP: listener ensure (LB ARNs unknown)"
fi

# ---------------- verification (strict, tunable) ----------------
ok=1

# 1) Every LB: UDP:514 forwards to our TG?
if [[ "$SKIP_LISTENER" -eq 0 ]]; then
  for LB in $LB_ARNS; do
    LSN_TG="$(aws elbv2 describe-listeners --load-balancer-arn "$LB" \
             --query "Listeners[?Protocol=='UDP' && Port==\`514\`].DefaultActions[0].TargetGroupArn" \
             --output text || true)"
    if [[ "$LSN_TG" != "$TG_ARN" ]]; then
      echo "[udp514] VERIFY FAIL: listener TG mismatch on $LB -> $LSN_TG"
      ok=0
    fi
  done
else
  echo "[udp514] SKIP VERIFY: listener (LB ARNs unknown)"
fi

# 2) ASG attached to our TG?
if ! aws autoscaling describe-load-balancer-target-groups \
     --auto-scaling-group-name "$ASG_NAME" \
     --query 'LoadBalancerTargetGroups[].LoadBalancerTargetGroupARN' --output text \
     | tr '\t' '\n' | grep -Fxq "$TG_ARN"; then
  echo "[udp514] VERIFY FAIL: TG not attached to ASG"
  ok=0
fi

# 3) My instance becomes Healthy in the TG (wait up to VERIFY_MAX secs)
healthy=0
loops=$(( VERIFY_MAX / 5 ))
[[ $loops -lt 1 ]] && loops=1
for _ in $(seq 1 "$loops"); do
  ST=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query "TargetHealthDescriptions[?Target.Id=='$IID'].TargetHealth.State" --output text || true)
  if [[ "$ST" == "healthy" ]]; then healthy=1; break; fi
  sleep 5
done
if [[ $healthy -ne 1 ]]; then
  echo "[udp514] VERIFY FAIL: instance $IID not healthy in TG $TG_NAME (timeout=${VERIFY_MAX}s)"
  ok=0
fi

if [[ $ok -eq 1 ]]; then
  echo "[udp514] VERIFIED OK. $(date -Is)"
  exit 0
else
  echo "[udp514] VERIFICATION FAILED. strict=${STRICT} $(date -Is)"
  if [[ "$STRICT" == "1" ]]; then exit 1; else exit 0; fi
fi
