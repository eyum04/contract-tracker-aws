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




