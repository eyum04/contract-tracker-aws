# Build notes

## Phase 0: Account security

### What I built
- Root MFA: root-google-authenticator, root-passkey-<device>
- Tested: signed out and back in with MFA

### What broke
- Adding the second MFA device failed saying "ensure you're authenticated with an MFA device."
- Cause: my session started before the MFA was on.
- Fix: signed out and back in.

### What I learned
- AWS has no backup codes, so a second MFA device is the backup.
