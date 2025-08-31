# AWS-Beanstalk-Syslog-Forwarder
Since AWS-Beanstalk is not designed to collect UDP streams, but there are no other AWS native external syslog collertor service,
i decided to customize AWS beanstalk to somehow collect UDP streams.

It is easy to manage auto-scaled EC2s with automatic OS / package patch management.

Forward external **syslog UDP/514** traffic through an **AWS NLB** to your **Elastic Beanstalk** instances on **UDP/5140**, with health-checked delivery.
This repo contains minimal Beanstalk hooks that:

* Create/ensure a **Target Group** `tg-eb-udp-5140` (UDP/5140, **health check: TCP/5140**)
* **Attach** that TG to the environment’s (or immutable update’s temporary) **Auto Scaling Group**
* **Create/modify** an **NLB listener** **UDP/514 → TG**
* **Verify** the instance becomes **Healthy** in the TG (configurable strictness & timeouts)
* Optionally add a small **swapfile** for tiny instances (e.g., `t3.micro`)

> These hooks are **idempotent**, use **IMDSv2**, and are resilient to **Managed Platform Updates (Immutable)** that spin up a temporary ASG.

---
<img width="963" height="320" alt="image" src="https://github.com/user-attachments/assets/5f731a8e-557c-4394-ac79-c6d756d55313" />

## How It Works

1. Post-deploy hook runs on each instance.
2. Discovers Region, Instance ID, and **the ASG that launched this instance**.
3. Robust discovery to obtain VPC and LB ARNs (works even during **immutable** transitions):

   * ASG → LoadBalancerTargetGroups
   * ASG → TargetGroupARNs
   * Reverse lookup: find any TG that already contains this instance
   * Falls back to **VPC from IMDS** if TGs are not yet visible
4. Ensures **TG `tg-eb-udp-5140`** exists (UDP/5140, HC TCP/5140).
5. **Attaches** the TG to the current ASG (safe if already attached).
6. Ensures each discovered **LB** has a **UDP/514** listener forwarding to the TG.
7. Waits for the instance to become **Healthy** in the TG (tunable).

   * **Strict** mode: fail the deployment if verification fails
   * **Non-strict**: log a warning and continue

---

## Beanstalk Environment Setting
Screenshot of last successful settings
<img width="1487" height="4039" alt="image" src="https://github.com/user-attachments/assets/6eb922c4-b0a9-44ca-bf4d-e91253406534" />
<img width="1480" height="3548" alt="image" src="https://github.com/user-attachments/assets/a0e38f23-63f0-44f1-9fd0-1525999337e9" />


---
## Folder Layout

Make this files into ZIP file, and upload it as a app in AWS Beastalk

```
(Your App Root)
├─ .ebextensions/
│  └─ 00-options.config                 # optional defaults
└─ .platform/
│  └─ hooks/
│     ├─ predeploy/
│     │  ├─ 05-swap.sh                  # optional (swapfile) Only when you deploy this in small instance ex:t3.micro
│     └─ postdeploy/
│        └─ 60-ensure-udp514-to-5140.sh # REQUIRED
│        └─ 40-restart-fluentd.sh # REQUIRED
├─ config/
│  └─ fluentd.conf
└─ Procfile # It deploy dummy web deamon to pass health check.
```

## Requirements

* **Elastic Beanstalk** on **Amazon Linux 2023** (any platform family; hooks are shell-based)
* An **NLB** associated with your EB environment’s ASG (directly or via TGs)
* **Security Groups**:

  * Instance SG **inbound UDP/5140** from the NLB
  * NLB TG targets set to **instance** type
* Beanstalk environment with **Ruby** + **Amazon Linux 2023**
* **IAM Role (EC2 Instance Profile)** needs:
```
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Action": [
				"autoscaling:DescribeAutoScalingInstances",
				"autoscaling:DescribeLoadBalancerTargetGroups",
				"autoscaling:AttachLoadBalancerTargetGroups",
				"autoscaling:DescribeAutoScalingGroups"
			],
			"Resource": "*"
		},
		{
			"Effect": "Allow",
			"Action": [
				"elasticloadbalancing:DescribeTargetGroups",
				"elasticloadbalancing:DescribeListeners",
				"elasticloadbalancing:DescribeTargetHealth",
				"elasticloadbalancing:CreateTargetGroup",
				"elasticloadbalancing:CreateListener",
				"elasticloadbalancing:ModifyListener"
			],
			"Resource": "*"
		}
	]
}
```
If you use AWS Firehose for output of fluentd. (You will for most of cases)
```
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Action": [
				"firehose:PutRecord",
				"firehose:PutRecordBatch",
				"firehose:DescribeDeliveryStream",
				"firehose:ListDeliveryStreams"
			],
			"Resource": "your firehose arn"
		}
	]
}
```


---

## Quick Start

<img width="599" height="185" alt="image" src="https://github.com/user-attachments/assets/23348fec-1087-45f8-983e-3e1f3ffdfbbd" />

<img width="1063" height="641" alt="image" src="https://github.com/user-attachments/assets/f93c8edb-2e29-4d25-917f-eab9b157d9a4" />

1. **Add files** from this repo into your ZIP file, upload to AWS Beanstalk, and deploy.
  (**Change foldername platform -> .platform, ebextensions-> .ebextensions**)
3. (Optional) Set **Environment Properties** in EB → Configuration → Software:

   * `UDP514_STRICT_VERIFY=1` (default)
   * `UDP514_VERIFY_MAX_SECS=180` (default)
   * `UDP514_DISCOVER_MAX_SECS=300` (default)
   * `SWAP_SIZE_GB=2` (if using the swap hook)
4. Edit /config/fluentd.conf to your preference
5. Ensure your **Instance SG** allows **UDP/5140** from the NLB.
6. Deploy. The hook will:

   * Create TG `tg-eb-udp-5140` if missing (UDP/5140, HC TCP/5140)
   * Attach TG to the ASG
   * Create/point NLB **UDP/514** listener to that TG
   * Verify target health and exit accordingly

---

## Configuration (Environment Properties)

| Key                        | Default | Description                                                                             |
| -------------------------- | ------- | --------------------------------------------------------------------------------------- |
| `UDP514_STRICT_VERIFY`     | `1`     | `1`: fail deployment on verification failure; `0`: warn and continue.                   |
| `UDP514_VERIFY_MAX_SECS`   | `180`   | Max seconds to wait until this instance becomes **Healthy** in the TG.                  |
| `UDP514_DISCOVER_MAX_SECS` | `300`   | Max seconds to wait for **LB/TG visibility** during discovery (immutable updates).      |
| `SWAP_SIZE_GB`             | –       | If set (e.g., `2`), predeploy hook will create a swapfile to stabilize small instances. |

---

## Optional Hardening for Small Instances

* `.platform/hooks/predeploy/05-swap.sh` – creates a swapfile (e.g., `SWAP_SIZE_GB=2`)
* Consider enabling **T3/T4g Unlimited** for smoother spikes during deploys.

---

## Managed Platform Updates (Immutable)

During EB **Managed Updates**, AWS creates a **temporary ASG** and launches fresh instances.
This project **doesn’t need to detect “immutable” explicitly**. It always targets **the ASG that launched the current instance**:

* **TG `tg-eb-udp-5140`** is ensured/attached to that ASG as soon as the hook runs.
* If the LB ARNs are not yet visible, the hook still creates the TG and attaches it;
  listener creation is **safely skipped** that run and performed the next time LB is visible.
* Use `UDP514_VERIFY_MAX_SECS`/`UDP514_DISCOVER_MAX_SECS` to tune waiting behavior.
  If strict failures are disruptive during updates, temporarily set `UDP514_STRICT_VERIFY=0`.

---

## Logging & Troubleshooting

* Primary log: `/var/log/eb-hooks.log` (the script appends to this file)
* EB engine: `/var/log/eb-engine.log`
* Common issues:

  * **AccessDenied** on ELB APIs → missing IAM permissions (see list above)
  * **Verification timeout** → increase `UDP514_VERIFY_MAX_SECS`; ensure SG/NACL allow health check (TCP/5140) and traffic
  * **LB not discoverable yet** during immutable → increase `UDP514_DISCOVER_MAX_SECS` or let next run correct it
  * **t3.micro instability** → enable swap (`SWAP_SIZE_GB=2`) and consider T3 Unlimited

---

## Security Notes

* Hooks create listeners and attach target groups; review **change-control** around load balancers.
* Restrict Security Groups to necessary sources (e.g., only your firewalls for UDP/514 to the NLB).

---

## License

MIT

---

## Disclaimer

This project automates NLB listener/TG management inside EB hooks.
Always validate in a **non-production** environment first and monitor logs during your first deployments.
