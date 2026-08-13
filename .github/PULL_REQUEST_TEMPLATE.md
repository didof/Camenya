## Outcome

<!-- What changes for the user, and why does this belong in Camenya? -->

## Scope

<!-- What is intentionally included and excluded? Link the issue. -->

## Invariant impact

- [ ] Pause, Resume, Flip, Take, Segment, and Project Export semantics remain unchanged or the change is explained above.
- [ ] Recoverable media is preserved across every new failure and cancellation path.
- [ ] Unfinished media remains local to the device.
- [ ] Official distribution remains source-only and self-signed by each user.
- [ ] No Apple Team, device, certificate, profile, account, personal bundle, machine-path, or raw-log identity is included.
- [ ] No compiled/signed bundle, entitlement, capability, network path, cloud service, telemetry, advertising, payment code, or third-party dependency is added.

<!-- If any box cannot be checked, this is a protected or constitutional change. Link the approved governance decision. -->

## Failure and recovery

<!-- Describe interruption, cancellation, low-storage, denied-permission, export, and retry behavior where applicable. -->

## Verification

- [ ] `Scripts/verify-public-repository.sh`
- [ ] `git diff --check`
- [ ] Required unsigned generic iOS Simulator build
- [ ] Relevant automated tests
- [ ] Every commit contains a matching DCO `Signed-off-by` line

Physical iPhone verification:

- [ ] Not required for this change
- [ ] Required but not performed; the pull request must not claim physical verification
- [ ] Performed on the exact head commit; results are described below without device or signing identifiers

<!-- Record observable results, not private device metadata. -->

## Reviewer focus

<!-- Where is careful human judgment most important? -->
