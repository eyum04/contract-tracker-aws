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
