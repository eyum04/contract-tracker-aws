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
