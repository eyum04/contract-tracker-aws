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
