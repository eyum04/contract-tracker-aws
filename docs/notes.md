# Build notes

## Phase 0: Account security

I secured the root user with MFA using both an authenticator app and a
passkey. AWS doesn't issue backup codes, so I registered a second device so a
lost phone can't lock me out of the account. My first attempt to add the second
device failed because my session started before MFA was on. Signing out and
back in fixed it.

The account already had an IAM user (`eyoel`) in an admin group, so I reused
it instead of creating a new one. It had no MFA and a 102-day-old password, so
I added a passkey and rotated the password. I also found a 102-day-old access
key, which I deactivated instead of deleting, in case something still
depended on it. I'll delete it after a couple of days if nothing breaks.

**Why:** daily work should use a revocable, MFA-protected identity, with root
kept locked away for the few tasks only it can do. Long-lived access keys are
a leak risk, so I'll use roles and temporary credentials wherever possible.

## Phase 0, continued: Billing safety

I set up three budgets ($1, $5, and $20 per month) so I get an email alert
long before a mistake can turn into a real bill.

I checked my credits on Oct 13, 2026. I have $113.27 remaining out of about
$140 total. All three credits expire on 07/03/2027, which is 12 months after
I created the account.

**Free plan vs credits:** The Free plan ends Jan 3, 2027 (6 months after
account creation), but the credits last 12 months. These are two separate
clocks. I plan to upgrade to the Paid plan in early December 2026. Credits
carry over when you upgrade, so nothing is lost.

**Why:** Knowing the plan end date and the credit expiry date separately
means I won't be surprised by the Free plan closing before my credits run out.


## Phase 1: Networking

### Step 1.1: VPC

I created a custom VPC named `ct-vpc` in us-west-2 (Oregon) with the CIDR
block 10.0.0.0/16. That gives me about 65,000 private IP addresses to divide
into subnets. VPC ID: `vpc-0362e89976389ba8c`.

My account also has a default VPC (172.31.0.0/16) that AWS creates in every
region. I left it untouched. Its subnets are all public, so it isn't suited
to a 3-tier design. I built my own VPC so I control the network layout.

**Why:** I used "VPC only" instead of the "VPC and more" wizard so I create
each piece (subnets, gateways, route tables) by hand and understand what
each one does.


### Step 1.2–1.3: Subnets

I split `ct-vpc` into six /24 subnets across two availability zones
(us-west-2a and us-west-2b). I only used two AZs because that is the minimum
for high availability, and more would add cost without benefit here.

| Name | AZ | CIDR | Tier |
|---|---|---|---|
| ct-public-a | us-west-2a | 10.0.1.0/24 | Public |
| ct-public-b | us-west-2b | 10.0.2.0/24 | Public |
| ct-app-a | us-west-2a | 10.0.11.0/24 | App (private) |
| ct-app-b | us-west-2b | 10.0.12.0/24 | App (private) |
| ct-db-a | us-west-2a | 10.0.21.0/24 | Database (private) |
| ct-db-b | us-west-2b | 10.0.22.0/24 | Database (private) |

**Why:** Three tiers means the internet can only reach the load balancer. The
app servers sit behind it, and the database sits behind the app servers with
no internet route. Each layer limits the damage if the one in front is breached.

Right after creation none of these subnets are "public". A subnet only
becomes public once its route table sends internet traffic to an internet
gateway. That is the next step.


### Step 1.4: Internet gateway

I created an internet gateway named `ct-igw` and attached it to `ct-vpc`.
Creating and attaching are separate actions. Just attaching it does nothing
by itself, because no subnet knows to send traffic to it yet. The default
VPC has its own IGW, which I left alone.


### Step 1.5: Public route table

I created a route table named `ct-public-rt` with two routes:

| Destination | Target |
|---|---|
| 10.0.0.0/16 | local |
| 0.0.0.0/0 | ct-igw |

I associated it with `ct-public-a` and `ct-public-b` only. A subnet is
"public" because its route table sends internet traffic to an IGW, not
because of its name.

I did not edit the VPC's main route table. Every new subnet uses the main
table by default, so it stays private. Adding the internet route there would
have made every subnet public.

**Why 0.0.0.0/0 works as a default route:** it matches every IPv4 address,
but AWS always picks the most specific matching route. Traffic to an address
inside 10.0.0.0/16 matches the local route, which is more specific, so it
stays in the VPC. Everything else falls through to the IGW.



### Step 1.6: App and database route tables

I created two more route tables so each tier has its own:

| Route table | Subnets | Routes |
|---|---|---|
| ct-public-rt | ct-public-a, ct-public-b | local, 0.0.0.0/0 → ct-igw |
| ct-app-rt | ct-app-a, ct-app-b | local only (for now) |
| ct-db-rt | ct-db-a, ct-db-b | local only |

All six subnets have explicit associations, so the main route table has no
subnets on it.

**Why:** The database tier has no route to the internet, so it can only talk
to other resources inside the VPC. The app tier gets its own table now
because in Phase 5 it will get a route to a NAT gateway for outbound-only
internet access, and I don't want that route to affect the database tier.


### Step 1.7: S3 gateway endpoint

I created a gateway endpoint for S3 (`ct-s3-endpoint`) and added it only to
`ct-app-rt`. It adds a route that sends S3 traffic over the AWS network
instead of the internet. Gateway endpoints are free, while the Interface
type costs money, so I made sure to pick Gateway.

**Why only the app tier:** the web servers are the only thing that talks to
S3. The database and public tiers don't need that path, and not giving it to
them follows least privilege. Without the endpoint, S3 traffic from the
private subnets would have to go through a NAT gateway, which charges per GB.


### Phase 1 summary

I verified the network with the VPC resource map:
- Only `ct-public-rt` connects to the internet gateway, and it serves the
  two public subnets.
- `ct-app-rt` and `ct-db-rt` have no path to the internet.
- `ct-app-rt` also connects to the S3 gateway endpoint, because the app
  servers are the only tier that talks to S3.

Nothing built in Phase 1 costs money. VPCs, subnets, route tables, internet
gateways and gateway endpoints are free, so I can leave them running between
sessions.

**What I learned:** a subnet is public or private because of its route
table, not its name. Subnet tiers, per-tier route tables and a gateway
endpoint are all small decisions that follow least privilege.


## Phase 2: Security groups

I created three security groups in `ct-vpc` and chained them together so each
tier only accepts traffic from the tier in front of it:

| Security group | Inbound rule | Source |
|---|---|---|
| ct-alb-sg | HTTP (80) | 0.0.0.0/0 (the internet) |
| ct-app-sg | TCP 8080 | ct-alb-sg |
| ct-db-sg | PostgreSQL (5432) | ct-app-sg |

**Why reference security groups instead of IP ranges:** a security group
works as a stable name for a changing set of resources. Load balancer nodes
and auto-scaled servers get new IP addresses all the time, but the rule
"allow from ct-alb-sg" never needs updating. It is also tighter than allowing
a whole subnet range.

**Why the database only trusts the app tier:** the load balancer only
forwards web requests and has no reason to talk to the database. Reaching my
contract data means getting through the load balancer and then an app server.
That is defense in depth.

Security groups are stateful. If a request is allowed in, the response is
allowed back out automatically, so I don't need rules for return traffic.
Network ACLs are stateless and do need rules in both directions.

I left the outbound rules at the default (allow all). The app servers need to
reach Secrets Manager and S3 later. I can tighten them as an improvement.

Security groups are free, so I left them in place between sessions.



## Phase 3: Hello world behind a load balancer

Before adding a database and real code, I proved the path
internet → load balancer → private servers works with a tiny page. If I had
built everything at once and it failed, I wouldn't have known which layer
was broken.

**What I built:**
- A launch template (`ct-app-lt`): Amazon Linux 2023, t3.micro, no key pair,
  `ct-app-sg`, and user data that starts a small Python web server on port
  8080 with a `/health` endpoint.
- A target group (`ct-tg`): HTTP on port 8080, health check path `/health`.
  I first created it with the TCP protocol by mistake. An ALB needs HTTP
  target groups and the protocol can't be edited, so I deleted and recreated
  it.
- An Application Load Balancer (`ct-alb`): internet-facing in the two public
  subnets, security group `ct-alb-sg`, listener HTTP:80 forwarding to `ct-tg`.
- An Auto Scaling group (`ct-asg`): desired 2, min 2, max 4, in the private
  app subnets, ELB health checks on, target tracking on 50% average CPU.

**Why the ELB health check:** the default EC2 check only notices a dead
machine. The ELB check requests `/health`, so a crashed or hung app on a
running machine gets replaced.

**Why the ports differ:** the visitor connects to the ALB on port 80. The ALB
opens a separate connection to a server on port 8080, the only port
`ct-app-sg` allows, and only from `ct-alb-sg`.

**Proof it works:** requesting the ALB's DNS name repeatedly returned two
different hostnames, `ip-10-0-11-x` and `ip-10-0-12-x`, one server in each
AZ's app subnet. No server has a public IP.

**Cost:** from this phase on, resources bill by the hour (the ALB and two
t3.micro servers, about $0.05/hour together).




## Phase 4: IAM role, S3 bucket and database

### Step 4.1: Instance role

I created an IAM role named `ct-app-role` for EC2 and attached the AWS managed
policy `AmazonSSMManagedInstanceCore`. That lets me connect to the servers
with Session Manager later, so I never need SSH or a key pair. AWS also
created an instance profile with the same name, which is the wrapper that
attaches a role to an EC2 instance. I will add a custom policy for S3 and
Secrets Manager once the bucket and the secret exist.

**Why a role instead of access keys:** access keys are long-term and can leak
through code, logs, screenshots or Git commits. Role credentials are
temporary, AWS rotates them automatically, and nothing is stored on the
server, so there is nothing to steal from a file.

### Step 4.2: Attach the role to the launch template

I created version 2 of the launch template `ct-app-lt` (from version 1) with
the IAM instance profile `ct-app-role`. I set the Auto Scaling group `ct-asg`
to use the Latest version and started an instance refresh with a minimum
healthy percentage of 50.

**Why the servers don't get the role right away:** a launch template is only
a recipe, so servers already running from version 1 do not change. Only new
servers use version 2. The instance refresh replaces the old servers one at a
time, and the other keeps serving traffic, so the site stays up. This is
immutable infrastructure: replace servers instead of editing them.


### Step 4.3: S3 bucket

I created the bucket `ct-contracts-eyoel-1234` in us-west-2 with ACLs
disabled, Block all public access on, versioning enabled, default encryption
SSE-S3, and the tag `Project = contract-tracker`. I added a bucket policy that
denies any request not made over HTTPS.

| Protection | Risk it addresses |
|---|---|
| Block all public access | Contracts becoming public by a mistake in a policy or ACL |
| Versioning | Accidental overwrites or deletes, and some ransomware-style damage |
| Encryption (SSE-S3) | Data readable if the underlying storage were ever exposed |
| TLS-only policy | Files being read or written in plain text over the network |

The TLS policy is an explicit Deny on `aws:SecureTransport = false`. It grants
no access to anyone. It only removes an insecure way to use access that is
granted elsewhere (the app's IAM role, in Step 4.5).



### Step 4.4: PostgreSQL database

I created an RDS PostgreSQL 16 instance (`ct-db`) on a `db.t4g.micro`, Single-AZ,
with 20 GiB of storage, encryption on, 1-day automated backups, and
Performance Insights and Enhanced Monitoring off to save cost. The initial
database is named `contracts`.

It lives in a DB subnet group (`ct-db-subnet-group`) that contains only the two
database subnets. I created the subnet group by hand before the database,
because the wizard's "create new" option can include every subnet in the VPC.
Public access is off, and the security group is `ct-db-sg`, so only the app
tier can reach it on port 5432.

**Why the password is managed in Secrets Manager:** RDS creates the password
and rotates it. It never appears in my code or in this repo, and the app
fetches it at runtime using its IAM role.

**Why public access is off:** the database holds contract data. It has no
public IP, its subnets have no route to the internet, and its security group
only trusts the app tier.

**Cost trade-off:** Single-AZ keeps the cost down. In production I would use
Multi-AZ so the database survives an AZ failure.



### Step 4.5: Least-privilege access for the role

I added an inline policy named `ct-app-access` to `ct-app-role` that allows:
- `s3:PutObject`, `s3:GetObject` and the two multipart-upload actions on
  `contracts/*` in my one bucket only
- `secretsmanager:GetSecretValue` on the one database secret only

**Why this narrow:** if a server were ever compromised, the attacker could
only touch the contract files and read one secret, not every bucket in the
account. The policy is also a ready-made `aws_iam_role_policy` for the
Terraform rebuild.

**Exam link:** the secret is encrypted with the AWS-managed Secrets Manager
key. If it used a customer managed KMS key, the role would also need
`kms:Decrypt`, and the key policy would have to allow the role.

### Phase 4 summary

The servers now have an identity instead of stored keys, the bucket is locked
down four ways (no public access, versioning, encryption, HTTPS only), and
the database is private with its password managed by Secrets Manager. The app
gets the minimum access it needs through its IAM role.



## Phase 5: NAT gateway and the full app

### Step 5.1: NAT gateway

I created a NAT gateway (`ct-nat-a`) in the public subnet `ct-public-a` with an
Elastic IP. It lives in a public subnet because it needs a route to the
internet gateway to do its job. Private servers can start outbound
connections through it, but nothing from the internet can start a connection
to them.

**Cost:** about $0.045 per hour plus data, the biggest hourly charge in the
project. I delete it at the end of every session and recreate it at the start
of the next.

### Step 5.2: Route the app subnets through it

I added `0.0.0.0/0 → ct-nat-a` to `ct-app-rt`. It now has three routes: the
local route, the S3 gateway endpoint, and the NAT default route. I did not
touch `ct-db-rt`, so the database tier still has no path to the internet.

**Trade-off:** I use one NAT gateway in one AZ to save money. If that AZ
went down, the servers in the other AZ would lose outbound internet access.
Production uses one NAT gateway per AZ, each with its own route table.


### Step 5.3: Session Manager and the outbound path

I connected to a server with Session Manager. There is no SSH, no key pair and
no open inbound port. The connection works because the instance role has
`AmazonSSMManagedInstanceCore` and the server can reach the SSM service
through the NAT gateway.

- `curl https://checkip.amazonaws.com` printed the NAT gateway's Elastic IP,
  not an address of the server. The server has no public IP, so this proves
  outbound traffic goes server → NAT → internet gateway → internet.
- `curl localhost:8080/health` returned `ok`.
- `systemctl status hello` showed the service active and enabled. The
  server built itself from the launch template's user data.
- The service log showed `GET /health` requests every 30 seconds from
  `10.0.1.x` and `10.0.2.x`, the load balancer's nodes in my two public
  subnets.

**Troubleshooting:** the first server I tried showed "Not connected" with an
`i/o timeout` to the SSM endpoint. The error was logged before the NAT route
existed, and the agent was still retrying. I terminated the instance, the Auto
Scaling group launched a replacement, and the new one registered right away.
Replacing a server instead of repairing it is the immutable-infrastructure
idea in practice.


### Step 5.4: Deploy the full app (in progress)

I created version 3 of the launch template with the full app's user data
(settings for the bucket, the database secret and the database endpoint) and
started an instance refresh. The new servers in us-west-2b repeatedly failed
the target group's health checks, so the Auto Scaling group kept replacing
them. I stopped the loop by scaling the group to 0 and cancelling the refresh.

I have not found the cause yet. Tomorrow I will launch one server, connect with
Session Manager, and read `/var/log/user-data.log`, the `contracts` service
status and its journal, and check `/etc/contracts.env` for typos.

### End-of-session shutdown (first run)

In order: scaled the Auto Scaling group to 0, deleted the NAT gateway and
released its Elastic IP, deleted the load balancer, stopped the database
temporarily. Kept the VPC, subnets, route tables, security groups, target
group, launch template, S3 bucket and IAM role, which are free or nearly free.

Starting the next session is the same list in reverse: start the database,
create a new NAT gateway with a new Elastic IP, point `ct-app-rt` at it
(the old route shows as Blackhole), recreate the load balancer with the same
target group and security group, and set the Auto Scaling group back to 2.


## Phase 6: Break it on purpose

### Exercise 1: Terminate one server
- Prediction: app keeps working via the other AZ; ASG replaces the server. Correct.
- Observed: refreshes flipped between working and 504 for a while (the ALB kept sending ~half of requests to the dead target until health checks marked it unhealthy), then all requests worked.
- Target went to `draining` after ~1 min. Default deregistration delay is 300 s; shorten it for stateless apps (idea: 30 s).
- ASG launched a replacement in response to the unhealthy instance; replacement took ~5 min to Healthy.
- Lesson: failover is not instant. Detection time = health check interval x unhealthy threshold. Two AZs mean no single failure takes the app down.

### Exercise 2: Stop the app, not the server
- `sudo systemctl stop contracts` on one instance.
- EC2 status checks stayed 3/3 (they only test the VM). The ELB health check caught the dead app, target went draining, ASG launched a replacement.
- Lesson: ASG health check type = ELB is what makes the app self-healing, not just the VM.

### Exercise 3: Remove the ALB -> app SG rule (port 8080)
- Suspended ReplaceUnhealthy first so the ASG would not kill healthy servers, then deleted the rule.
- Result: both targets unhealthy, app returned 504 (packets silently dropped, ALB times out). Servers were never broken.
- Restored the rule: both targets Healthy in ~5 min with no other changes.
- Lesson: when targets are unhealthy but instances are fine, check the SG path first. SGs drop silently, they do not "reject".

### Exercise 4: Reach the DB from outside
- `nc -vz -w 5 <db-endpoint> 5432` from my laptop: "Operation timed out".
- Blocked by three independent layers: no public access, no route to the IGW for the DB subnets, and the SG only allows ct-app-sg on 5432. Defense in depth.

### Still to do next session
- Exercise 5: remove s3:PutObject from the inline policy, upload a file, find the AccessDenied in CloudTrail.
- Exercise 6: pin CPU (`yes > /dev/null &`) to watch target tracking scale out.
- Exercise 7 (optional): Multi-AZ failover for RDS.



## Phase 5: Deploy the real app

### 5.4 Debugging the crash loop
- Symptom: new instances kept failing ELB health checks and were replaced in a loop (instance refresh looked "stuck").
- Diagnosis path: ASG activity history -> user-data.log -> `systemctl status contracts` -> `journalctl -u contracts` -> import test showed `KeyError`.
- Root cause: `NAME=value` format belongs ONLY in `/etc/contracts.env`. I deleted the `NAME=` prefixes while replacing placeholders, then re-added them everywhere, which also changed the Python keys to `os.environ["BUCKET_NAME=..."]`.
- Fix: re-copied the clean script, replaced only the three `__PLACEHOLDER__` values in the env block, created launch template version 4, terminated the broken instance.
- Lesson: change one thing at a time, and read the log before guessing. ELB health checks catch an app that is crashed even when EC2 status checks pass.
- Lesson: suspending `ReplaceUnhealthy` stops the loop while debugging, but it also stops the ASG from replacing a manually terminated instance. Turn it back on once healthy.

### 5.5 End-to-end test
- Opened the ALB DNS name, added a contract with a PDF: row shows days left, file stored under `contracts/` in S3.
- Verified object encryption: SSE-S3.
- Path proven: ALB -> app (8080) -> Secrets Manager -> RDS (5432), and app -> S3 using the instance role (no access keys).



## Phase 6: Break it on purpose

### Exercise 1: Terminate one server
- Prediction: app keeps working via the other AZ; ASG replaces the server. Correct.
- Observed: refreshes flipped between working and 504 for a while (the ALB kept sending ~half of requests to the dead target until health checks marked it unhealthy), then all requests worked.
- Target went to `draining` after ~1 min. Default deregistration delay is 300 s; shorten it for stateless apps (idea: 30 s).
- ASG launched a replacement in response to the unhealthy instance; replacement took ~5 min to Healthy.
- Lesson: failover is not instant. Detection time = health check interval x unhealthy threshold. Two AZs mean no single failure takes the app down.

### Exercise 2: Stop the app, not the server
- `sudo systemctl stop contracts` on one instance.
- EC2 status checks stayed 3/3 (they only test the VM). The ELB health check caught the dead app, target went draining, ASG launched a replacement.
- Lesson: ASG health check type = ELB is what makes the app self-healing, not just the VM.

### Exercise 3: Remove the ALB -> app SG rule (port 8080)
- Suspended ReplaceUnhealthy first so the ASG would not kill healthy servers, then deleted the rule.
- Result: both targets unhealthy, app returned 504 (packets silently dropped, ALB times out). Servers were never broken.
- Restored the rule: both targets Healthy in ~5 min with no other changes.
- Lesson: when targets are unhealthy but instances are fine, check the SG path first. SGs drop silently, they do not "reject".

### Exercise 4: Reach the DB from outside
- `nc -vz -w 5 <db-endpoint> 5432` from my laptop: "Operation timed out".
- Blocked by three independent layers: no public access, no route to the IGW for the DB subnets, and the SG only allows ct-app-sg on 5432. Defense in depth.

### Shutdown (end of session 2)
- Order: ASG desired/min to 0 -> delete NAT -> release its EIP -> delete ALB (its 2 managed EIPs vanish on their own) -> stop DB -> verify.
- Kept: VPC, subnets, route tables, IGW, S3 endpoint, SGs, ct-tg, ct-asg (at 0), launch template, S3 bucket, secret, IAM role.
- Verified all clear: instances terminated, NAT deleted, no ALB, no EIPs, no volumes, DB stopped.
- Reminder: stopped RDS restarts automatically after 7 days.
- Next start-up: DB -> NAT (new EIP) -> repoint ct-app-rt route (old one shows Blackhole) -> ALB with same ct-tg + ct-alb-sg -> ASG back to 2.

### Still to do next session
- Exercise 5: remove s3:PutObject from the inline policy, upload a file, find the AccessDenied in CloudTrail.
- Exercise 6: pin CPU (`yes > /dev/null &`) to watch target tracking scale out.
- Exercise 7 (optional): Multi-AZ failover for RDS.



### Exercise 5: Remove s3:PutObject from the instance role

- Removed `s3:PutObject` from inline policy `ct-app-access`, then tried to add a contract with a PDF.
- Result: app returned 500 Internal Server Error at /contracts. Main page, health checks, and existing rows kept working.
- No row was created: the app uploads to S3 first, then inserts the DB row, so a failed upload leaves no "ghost" row.
- Diagnosis: `journalctl -u contracts` showed `AccessDenied ... s3:PutObject ... because no identity-based policy allows the s3:PutObject action` for `assumed-role/ct-app-role/<instance-id>`.
- CloudTrail Event history (free) only records management events; S3 object calls like PutObject are data events, so they need a trail with data events enabled (extra cost). Used the app log instead.
- Servers use `GetSecretValue`/`Decrypt` via the role, visible in CloudTrail as the instance-id session.
- Note: servers keep time in UTC, so use relative times (`--since "40 min ago"`) in journalctl.
- Restored the permission: upload worked again.
- Lesson: "no identity-based policy allows" = missing Allow (implicit deny). Least privilege means a missing action fails loudly and safely.



### Exercise 6: Scale out under load
- Found the ASG had NO dynamic scaling policy (I had assumed one existed). Created target tracking policy `ct-cpu-target`: average CPU 50%, warmup 120 s. Lesson: verify the thing you are about to test.
- Ran `for i in 1 2; do yes > /dev/null & done` on both servers (t3.micro = 2 vCPUs, so one `yes` is only ~50% of the instance). Policy uses the GROUP average, so every server needs load.
- Result: CPU reached ~89%, the high alarm fired, and the ASG added 2 instances at once (2 x 89/50 ~ 3.6, capped by max = 4). New targets went Healthy in ct-tg.
- Stopped load with `pkill yes`. After ~15-20 min the low alarm fired, instances drained, and the group returned to the minimum (2).
- Lesson: scale out fast, scale in slow, so the group does not flap.


## Terraform setup (session 4)

### Tools
- Installed Terraform via Homebrew tap: `brew tap hashicorp/tap`, `brew install hashicorp/tap/terraform` (v1.17.0).
- First install failed: "Your Command Line Tools are too outdated." Fix: `sudo rm -rf /Library/Developer/CommandLineTools`, then `sudo xcode-select --install`, then re-ran the brew install. Did NOT upgrade the whole OS (not needed).
- "Tier 2 configuration" message from Homebrew is harmless (unsupported-OS note).

### AWS credentials for the CLI
- `aws sts get-caller-identity` failed with InvalidClientTokenId: the key in `~/.aws/credentials` was Inactive (113 days old).
- Diagnosed with `aws configure list` (key came from the shared credentials file).
- Fix: deleted the inactive key in IAM -> Users -> eyoel -> Security credentials, created a new CLI key (tag `terraform-laptop`), saved it with `aws configure` (region us-west-2, output json), verified with `aws sts get-caller-identity`.
- Rules I follow: never use root keys, never put keys in Terraform files or GitHub, secret key is shown once.
- Later: use OIDC (no long-lived keys) for GitHub Actions; consider deleting the laptop key when not in use.



### Terraform project setup (done)
- Cloned the repo with `gh repo clone eyum04/contract-tracker-aws` after `gh auth login` (HTTPS, browser).
- Work from the VS Code terminal; it is the same shell as the Mac Terminal.
- `terraform/main.tf`: `terraform` block (required_version >= 1.5, aws provider ~> 6.0) + `provider "aws"` (region us-west-2). Provider = plug-in that teaches Terraform one platform.
- Bug: "Unclosed configuration block". Counted braces: 3 openers, 2 closers. One mistake produced 3 errors; fix the FIRST error first. `cat main.tf` + counting `{` vs `}` found it.
- `terraform fmt` standardizes spacing (2 spaces); `terraform init` downloads the provider (v6.70.0) and writes `.terraform.lock.hcl`.
- Commit `.terraform.lock.hcl` (pins provider version). NEVER commit `.terraform/` or `*.tfstate` (state = Terraform's memory, can hold secrets). Verified with `grep -n "tfstate" ../.gitignore`.
- git flow: `git add <files>` -> `git commit -m "..."` -> `git push`.


### Terraform: my first resource (a VPC)

Terraform is basically an instruction booklet for AWS. Instead of clicking through the console like I did before, I write a file that says what I want and Terraform builds it.

**What I did**
- Wrote a `resource "aws_vpc" "main"` block with the same 10.0.0.0/16 range as my console VPC. Named it ct-tf-vpc so I wouldn't mix it up with the one I built by hand.
- Ran `terraform plan` first (just a preview), then `terraform apply`. A VPC is free, so no cost risk.
- Terraform keeps a file called `terraform.tfstate`. It's its memory of what it built. It stays on my Mac and never goes on GitHub. I checked with `git check-ignore -v` that .gitignore covers it.

**Things I got wrong or learned the hard way**
- I thought the file was fine and it wasn't. I was missing one closing `}`, so Terraform said "unclosed configuration block" and then gave me two more errors that were really the same mistake. Lesson: fix the first error first, and count your brackets.
- My guess was that changing the VPC's cidr_block wouldn't need a new VPC. Wrong. The plan showed `-/+ must be replaced`. AWS lets you add address ranges but you can't change the main one.

**How I read a plan now**
`+` is create, `~` is change in place (like adding a tag), `-` is destroy, and `-/+` is destroy and rebuild. Before I type yes I look for the words "forces replacement."

**Commands so far**
- `terraform fmt` fixes spacing
- `terraform validate` checks the file makes sense
- `terraform plan` previews
- `terraform apply` builds



### Terraform: internet gateway and subnets

**Internet gateway**
- Wrote `aws_internet_gateway` with `vpc_id = aws_vpc.main.id`. That's a reference: type.nickname.property. I never type the real ID, Terraform fills it in and also figures out the build order (VPC first, gateway second) and destroys in the reverse order.
- The plan showed the real vpc_id instead of "known after apply" because the VPC already existed in the state. My guess on that was right, and I'd only have seen "known after apply" if both were new.

**Subnets**
- First I wrote one subnet by hand so I understood every line. The line `availability_zone` is what decides the data center, not vpc_id. vpc_id just says which VPC.
- Then I turned it into a loop. `locals` is a notepad with a roster of 6 subnets (name, cidr, az). `for_each = local.subnets` makes one copy of the block per row. `each.key` is the row name, `each.value` is its details, `${each.key}` puts a value inside text.
- Result: one template, six subnets, and adding a seventh is a one-line change to the roster.
- My numbering: public .1/.2, app .11/.12, db .21/.22, one of each tier in each zone.
- I named the resource `subnets` instead of `this`. If I rename after apply, Terraform would destroy and recreate it, so pick a clear name before applying.


### Terraform: route tables

- Why a `tier` label on each subnet: so one block can sort the subnets automatically (public ones go with the public route table, and so on) instead of me writing six hookups by hand. In the hookup block, `each.value.tier` picks the matching route table.
- Made the 3 route tables with one block: a list of tiers turned into a set with `toset(...)`, then `for_each`. With a set, `each.key` is just the word itself ("public").
- The public route is `0.0.0.0/0` through the internet gateway. That route is what makes a subnet "public". The app and db tables only have the local route.
- Left out the app -> NAT route on purpose because the NAT gateway costs money per hour. I'll add it later behind an on/off switch.
- One apply made 10 things (3 route tables, 1 route, 6 associations). `terraform state list` shows 18 things in total now.
- Checked in the console: ct-tf-public-rt has the igw route and public-a/public-b, and app and db only have local.
- Mistakes this time: typed `git add terraform/main.tf` while already inside the terraform folder (wrong path), and a pull typo (`--n rebase` instead of `--no-rebase`). Also git rejected my push because I'd edited on the GitHub website. Pull before you push.



### Terraform: security groups

- A security group is a bouncer for a server. Each rule is a line on the bouncer's list. In Terraform, the group (`aws_security_group`) and each rule (`aws_vpc_security_group_ingress_rule` / `_egress_rule`) are separate blocks.
- Terraform removes the default "allow all outbound" rule, so I have to write egress rules myself. If I forget, the load balancer can't reach the servers even though everything looks right.
- Typo I made: wrote `aws_security_group_ingress_rule` and left out `vpc_`. Terraform said "provider does not support resource type". Resource type names have to match exactly. The VS Code suggestion list helps.
- The chain: internet -> alb (80) -> app (8080) -> db (5432). Each rule uses `referenced_security_group_id` to point at the group in front of it, instead of an IP range.
- The first line of every rule (`security_group_id`) says which bouncer the rule is on. I almost put the db rule on the app group. Always read that line.
- A rule is about who can come IN to this group, not where it goes. The db only lets the app in (least privilege). I left the db with no outbound rule on purpose, since the database never starts connections and replies are allowed automatically (stateful).
- 8 things added in one apply. Free.
- Ran `terraform` from the main repo folder by mistake and got "No configuration files". Terraform commands run from the terraform folder.


### Terraform: S3 bucket and IAM role

**Variable**
- A variable (`variable "bucket_name"` in variables.tf) is a blank on a form. I use it as `var.bucket_name`. I made the bucket name one because S3 names have to be unique in the whole world, and the name shows up in several places (bucket, policy, role permissions), so writing it once keeps them from disagreeing.

**S3 bucket**
- The console settings became separate blocks: bucket, public access block, versioning, encryption (`sse_algorithm = "AES256"` is SSE-S3), and the TLS-only policy.
- The TLS-only policy is a Deny on `aws:SecureTransport = "false"`, so only insecure connections get blocked. `jsonencode` turns Terraform into the JSON AWS wants. `.arn` gives a resource's full address.
- `depends_on` makes it wait for the public access block first, because S3 gets cranky when two settings change at once.

**IAM role**
- Two lists people mix up: the trust policy (who may wear the role: ec2.amazonaws.com) and the permission policies (what the role can do).
- The instance profile is the hanger that lets an EC2 server pick up the role. The console made it for me quietly; Terraform makes me write it.
- The permissions only allow 4 S3 actions and only on `contracts/*` (least privilege). I left the secret permission out for now because the database doesn't exist yet. I'll add it later and Terraform should show it as `~` (change in place).
- I mistyped nothing this time, but I almost forgot the ARN in the policy has to point at the bucket by reference, not a copy-pasted name.


### Terraform: the on/off switch (stack_up)

- Some things cost money every hour (NAT gateway, load balancer, servers, database). I made a true/false variable `stack_up` that defaults to false, like a light switch. `-var="stack_up=true"` flips it for one command only; the next command springs back to off.
- `count = var.stack_up ? 1 : 0` means: if the switch is on, make 1 copy, otherwise make 0. Zero copies means the block doesn't exist. When count makes copies they're numbered from 0, so I point at them as `aws_eip.nat[0]`.
- NAT chain: elastic IP -> NAT gateway (in public-a) -> route on the app route table (`0.0.0.0/0` through the NAT). Not on the public table (it already has the internet gateway) and not on the db table (no way out on purpose). `depends_on` makes the NAT wait for the internet gateway.
- Typos Terraform caught: `var.stack_up` used before I declared it in variables.tf, and a subnet key `["public"]` when the roster key is `"public-a"`. Both were caught by validate/plan before touching AWS.
- Load balancer: target group is free so it always exists; the load balancer and listener are behind the switch. I put my Phase 6 lessons in the target group: health check every 15s and `deregistration_delay = 30`.
- Missing a closing `}` again (target group). I found it myself by counting openers and closers.
- Rule I follow: never apply with `stack_up=true` unless I'm ready to pay by the hour.


 ### Terraform: secret permission only when the database exists

- The policy's Statement is a list of "hall passes." Pass 1 is the S3 pass (always there). Pass 2 is the secret pass, which should only exist when the database exists.
- `concat(list1, list2)` glues two lists. `var.stack_up ? [pass 2] : []` means: if the switch is on, a list with pass 2, otherwise an empty list. Together, the pass disappears with the database.
- Plan results: switch off = "No changes." Switch on = "6 to add, 1 to change, 0 to destroy", where the 1 change is the policy (`~`).
- Bracket kinds: `( )` are inputs to a function, `[ ]` is a list, `{ }` is one thing with settings. I typed `concat{` instead of `concat(`, and VS Code's auto-closing left a stray `}` that made an empty pass.
- Sid can only be letters and numbers (no spaces). Terraform doesn't know that; AWS would reject it at apply. `validate` only checks my file is well-formed, not AWS's own rules.


## Terraform: launch template (the server recipe)

- A launch template is the recipe the Auto Scaling group uses to make a new server: which image, what size, which security group, which role, and a startup script.
- A `data` block only looks something up. I used one to ask AWS for the newest Amazon Linux 2023 image so I'm not hardcoding an image ID that goes out of date. It never shows up as "to add" in a plan, because it builds nothing.
- I put `count = var.stack_up ? 1 : 0` on it. I first thought that was just so it turns on with the switch. It's also because the startup script points at the database, and the database only exists when the switch is on.
- The instance profile is the holder that lets the server wear the IAM role. Without it the app would load but fail with AccessDenied on the secret and S3.
- I turned the old startup script into a template file with three blanks: `${bucket_name}`, `${secret_arn}`, `${db_endpoint}`. `templatefile` fills them in. The secret ARN comes from `aws_db_instance.db[0].master_user_secret[0].secret_arn` because AWS makes that secret itself.
- Predicted the plan would print the whole script. Wrong. It says `(known after apply)` because the database doesn't exist yet, so Terraform can't fill in the blanks.
- Mistakes I made: ran `plan` from the repo root instead of the `terraform` folder, put a line break after `user_data =`, and named the file `user-data.sh` in the code when the real file is `user_data.sh.tpl`. Terraform's error message told me exactly which file it couldn't find.
- IMDSv2: the server keeps a note with its hall pass keys. The old way lets anyone ask for the note. The new way makes you get a ticket first, so a trick through the web app can't grab it. `http_tokens = "required"` turns the old way off. The app still works because boto3 gets the ticket by itself.
- Plan with the switch on: 7 to add, 1 to change, 0 to destroy. With it off: no changes.


## Terraform: Auto Scaling group and scaling policy

- The launch template is the recipe. The Auto Scaling group is the manager that follows it. It keeps 2 servers (min 2, max 4), one in each app subnet, and registers them with the load balancer.
- I put `health_check_type = "ELB"` so the load balancer decides if a server is healthy. From my Exercise 2 test, a server can look fine to EC2 while the app is dead. Only the ELB check catches that.
- `health_check_grace_period = 300` gives a new server 5 minutes to boot before it can be judged unhealthy.
- `depends_on = [aws_route.app_nat]` makes Terraform build the NAT route before the servers. A new server downloads Python and its libraries when it boots, so it has to have a way out to the internet first.
- The ASG and the policy both have `count` behind my `stack_up` switch, so they use `[0]` when other resources point at them.
- The scaling policy works like a thermostat: target 50% average CPU. Above it, the ASG adds servers (up to 4). Below it, it removes them slowly (down to 2). Same as my load test in the console build.
- Plan with the switch on: 9 to add, 1 to change, 0 to destroy. I have not applied it yet. Applying with the switch on costs about $0.12 per hour.


## Terraform: output for the app's address

- An `output` block tells Terraform to print something when it finishes. I used it to print the load balancer's address, so I don't have to hunt for it in the console.
- The load balancer only exists when `stack_up` is true, so `aws_lb.app[0]` doesn't exist when the switch is off. I used the same `? :` choice as the other switch blocks: if on, build the address, otherwise print "stack is off".
- I put a line break after the `:` and VS Code showed a red squiggle. Terraform wants the whole `? :` on one line. Same mistake I made with `user_data =` earlier.
- Plan with the switch off: no resource changes, only `+ app_url = "stack is off"`. Plan with it on: 9 to add, 1 to change, 0 to destroy, and `app_url` is "known after apply".
- Next: first full stack-up with `terraform apply -var="stack_up=true"`.