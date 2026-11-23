# Contract Tracker on AWS

A contract expiration tracker built as a three-tier application on AWS. Users add a contract (name, expiration date, PDF) and see how many days are left. It is deliberately built to be secure, highly available, and cheap to run in a learning budget.

> **Status:** console build complete and tested (Phases 0–6). The whole stack is now rebuilt in Terraform with remote state in S3, and a GitHub Actions pipeline (OIDC, plan-only) checks every pull request. Next: security scans, a demo video, containers and monitoring.

## Architecture

```mermaid
flowchart TB
    user([Internet users])
    subgraph vpc["VPC 10.0.0.0/16 - us-west-2"]
        igw[Internet gateway]
        subgraph pubtier["Public tier - 2 subnets, 2 AZs"]
            alb["Application Load Balancer<br/>ct-alb - SG ct-alb-sg"]
            nat["NAT gateway<br/>ct-nat-a"]
        end
        subgraph apptier["App tier - 2 private subnets, 2 AZs"]
            asg["Auto Scaling group<br/>EC2 t3.micro, 2 to 4 instances<br/>Flask + gunicorn on 8080<br/>SG ct-app-sg"]
        end
        subgraph dbtier["DB tier - 2 private subnets, 2 AZs"]
            rds[("RDS PostgreSQL 16<br/>db.t4g.micro - SG ct-db-sg")]
        end
        s3ep{{"S3 gateway endpoint"}}
    end
    s3[("S3 bucket<br/>private - SSE-S3 - TLS only")]
    sm["Secrets Manager<br/>DB credentials"]

    user -->|"HTTP 80"| igw --> alb
    alb -->|"8080"| asg
    asg -->|"5432"| rds
    asg --> s3ep --> s3
    asg -->|"outbound only"| nat --> igw
    asg -.->|"GetSecretValue"| sm
```

**Request flow:** browser -> internet gateway -> ALB (public subnets) -> app servers (private subnets, port 8080) -> PostgreSQL (private subnets, port 5432). PDFs go to S3 through a gateway endpoint; DB credentials come from Secrets Manager at runtime.

## Design decisions

| Area | Decision | Why |
|---|---|---|
| Network | /16 VPC, six /24 subnets (public, app, DB x 2 AZs), one route table per tier | Clear separation; a subnet is "public" only because its route table points at the internet gateway |
| Security groups | Chained by reference: internet -> `ct-alb-sg` (80) -> `ct-app-sg` (8080) -> `ct-db-sg` (5432) | Each tier accepts traffic only from the tier in front of it; no IP ranges to maintain |
| Credentials | EC2 instance role (temporary credentials), least-privilege inline policy, DB password in Secrets Manager | No access keys on servers or in code |
| Access to servers | Session Manager, no SSH, no key pairs, no open port 22 | Smaller attack surface, audited access |
| Storage | S3 with block public access, versioning, SSE-S3, and a TLS-only bucket policy | Contracts are sensitive documents |
| Database | RDS PostgreSQL in private subnets, public access off | Only the app tier can reach it |
| Availability | ALB + Auto Scaling group across two AZs, ELB health checks, target tracking on CPU (50%) | Survives a server or AZ failure; scales with load |
| Deployments | Launch template versions + instance refresh | Immutable servers: replace, never patch in place |
| Health check | `/health` does not touch the DB (shallow check) | A DB outage should not pull every server out of rotation |

## Screenshots

![App working](docs/screenshots/app-working.png)
*The deployed app: a contract with its days left and the S3 key of the uploaded PDF.*

![Healthy targets](docs/screenshots/targets-healthy.png)
*Target group showing healthy servers behind the load balancer.*

![S3 encryption](docs/screenshots/s3-encryption.png)
*Uploaded contract stored with server-side encryption (SSE-S3).*

![VPC resource map](docs/screenshots/vpc-resource-map.png)
*VPC resource map: six subnets across two AZs and three route tables.*

## What I tested on purpose (Phase 6)

| Exercise | What I did | What happened | What I learned |
|---|---|---|---|
| Kill a server | Terminated one instance | Brief 504s, then all traffic went to the other AZ; ASG launched a replacement (~5 min) | Failover time = health check interval x unhealthy threshold |
| Stop the app, not the server | `systemctl stop contracts` | EC2 status stayed green; the ELB check caught it; ASG replaced it | ELB health checks catch dead apps that EC2 checks miss |
| Break the SG chain | Removed the ALB -> app rule on 8080 | Targets unhealthy, 504s, servers untouched | SGs drop silently; check the network path first |
| Probe the DB from outside | `nc -vz` to the endpoint on 5432 | Timed out | Three independent layers block it (no public IP, no route, SG) |
| Remove `s3:PutObject` | Edited the instance role policy | Upload returned 500; log showed `AccessDenied` for the role session; no ghost DB row | Missing Allow = implicit deny; the app uploads to S3 before inserting the row |
| Load test | Pinned CPU on both servers | ASG scaled out from 2 to 4, then back to 2 after ~15 min | Scale out fast, scale in slow to avoid flapping |

## Infrastructure as code (Terraform)

I built the stack by hand in the console first so I'd understand every piece, then rebuilt all of it in Terraform (in `terraform/`) and ran it end to end: it brought the app up, I uploaded a test contract, then I tore it down.

- `main.tf`: VPC, subnets, security groups, ALB, Auto Scaling group, RDS, S3 bucket and IAM roles
- `user_data.sh.tpl`: the startup script the servers run
- `variables.tf`: the bucket name and the `stack_up` switch
- `backend.tf`: keeps Terraform's state in S3 with locking instead of on my laptop
- `github_oidc.tf`: the role the GitHub Actions pipeline uses to log in

**The `stack_up` switch.** It defaults to `false`. While it's off, the hourly-cost pieces (NAT gateway, ALB, database) don't exist. Turning it on creates them (about $0.12 an hour) and prints the app URL.

To run it: `cd terraform`, `terraform init`, then `terraform apply -var="stack_up=true"`. To shut it down, run `terraform apply` again without the variable. The bucket names in `variables.tf` and `backend.tf` are mine, so anyone else would need to pick their own.


## CI/CD pipeline (GitHub Actions)

Every pull request, and every push to `main`, runs a workflow (`.github/workflows/terraform.yml`) that checks the Terraform with `fmt -check`, `init`, `validate` and `plan`.

**No AWS keys are stored in GitHub.** The workflow logs in with OIDC. GitHub gives each run a short-lived token, and an IAM role (`ct-tf-github-actions`) only trusts that token if it comes from this repo.

**Plan-only on purpose.** The role has read-only access, plus a few permissions on the state bucket (read the state, write the lock file). It can't create or delete anything, so a bad pull request can't break my account. I run `apply` myself.

**The bug that took the longest.** The login kept failing with "Not authorized to perform sts:AssumeRoleWithWebIdentity" even though my trust policy matched every tutorial. I printed the token's real `sub` claim and found that GitHub now puts numeric account and repo IDs in it, so the old format never matched. The full story is in `docs/notes.md`.

## Cost control

The whole stack costs about **$0.12 per hour** while running (ALB, NAT gateway, 2 x t3.micro, RDS). I run it in sessions and shut it down after each one: ASG to 0, delete the NAT gateway and release its Elastic IP, delete the ALB, stop the database, then verify nothing is left. In the Terraform version, a `stack_up` switch controls the hourly pieces (NAT gateway, ALB, database): with it off they don't exist, and one `apply` with it on brings the whole app up.

## Known limitations (trade-offs I chose on purpose)

- One NAT gateway in one AZ (outbound traffic is a single point of failure; a NAT per AZ would double that cost).
- RDS is Single-AZ; I did not run the Multi-AZ failover exercise.
- HTTP only on port 80 (no custom domain or TLS certificate yet).
- The S3 bucket uses SSE-S3 rather than a customer-managed KMS key.


## What I learned

**Debugging is the real skill.** My biggest outage was self-inflicted: while replacing placeholders in the server's startup script, I applied a `NAME=value` edit to the Python code as well as the config file, so the app crashed with a `KeyError` and the Auto Scaling group kept replacing servers in a loop. I found it by following the evidence in order (ASG activity -> startup log -> `systemctl status` -> `journalctl` -> an import test) instead of guessing. The fix was one line, and the lesson was to change one thing at a time and read the log first.

**Health checks have layers.** EC2 status checks only test the VM; the load balancer's health check is what catches a dead app. My `/health` route deliberately skips the database so a DB outage doesn't remove every server at once, but that means "healthy" can hide a broken DB-backed page. It's a trade-off, not a bug.

**Failover is not instant.** When I killed a server I saw about a minute of 504s, because the load balancer kept sending half the traffic to the dead target until enough health checks failed. Detection time is the check interval times the unhealthy threshold.

**Security is layers, not one setting.** The database is unreachable from the internet for three independent reasons (no public IP, no route to the internet gateway, and a security group that only accepts the app tier). I confirmed it from my laptop with a connection that timed out.

**Permissions fail loudly when they're least-privilege.** Removing `s3:PutObject` from the instance role returned a 500 and an `AccessDenied` in the app log naming the exact role session and action. I also learned the app uploads to S3 before writing the database row, so a failed upload leaves no orphan record.

**Check your assumptions before testing.** I assumed the Auto Scaling group already had a CPU scaling policy. It didn't, so I found that out before running the load test, not after wondering why nothing scaled. Scale-out was fast (two servers added within minutes) and scale-in was deliberately slow (about 15 minutes) to avoid flapping.

**Cost is a design constraint.** Hourly resources like the NAT gateway and load balancer made me design a repeatable shutdown and start-up routine, which is exactly why I'm rebuilding this in Terraform next.

**Mistakes I made along the way** (and fixed): created a TCP target group when the ALB needs HTTP; nearly used an RDS wizard mode that would have put the database in the default VPC; left an auto-replacement setting suspended, which stopped the group from replacing a server I terminated by hand.


## Roadmap

- [x] Rebuild the whole stack with Terraform (remote state)
- [x] GitHub Actions CI/CD with OIDC (no long-lived keys)
- [ ] tfsec/checkov scans in the pipeline
- [ ] Containerize the app; add monitoring and alarms
- [ ] HTTPS with ACM and a custom domain

## Repo layout

```
.
├── README.md
├── terraform/
│   ├── main.tf               # the whole stack
│   ├── user_data.sh.tpl      # server startup script
│   ├── variables.tf          # bucket name and the stack_up switch
│   ├── backend.tf            # remote state in S3
│   └── github_oidc.tf        # login role for the pipeline
├── .github/workflows/
│   └── terraform.yml         # the CI pipeline
└── docs/
    ├── notes.md              # build log: what I did, predictions, mistakes, lessons
    └── screenshots/
```
