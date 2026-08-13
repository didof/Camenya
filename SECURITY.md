# Security policy

Camenya records sensitive media and is distributed only as source code for users to inspect and self-build. The project does not operate a server, account system, update service, binary download, App Store listing, or signing service.

## Report a vulnerability

Use GitHub's private vulnerability reporting for this repository. Do not open a public issue for a vulnerability that could expose media, execute code, mislead users about a build, or compromise a development machine.

Do not include Apple credentials, certificates, private keys, provisioning profiles, Team IDs, device identifiers, personal bundle identifiers, raw Xcode logs, or private recordings. Replace local paths and identifiers with obvious placeholders and create the smallest synthetic reproduction possible.

If private vulnerability reporting is unavailable, open a public issue containing only a request for a private contact path and no vulnerability details.

## Scope

Useful reports include:

- unintended access to or disclosure of in-app media;
- unsafe file handling, path traversal, or destructive recovery behavior;
- installation scripts executing untrusted data or leaking local signing metadata;
- repository automation that could publish artifacts or expose contributor data;
- a way to make a modified or unsigned artifact appear to be an official Camenya release.

Reports about Apple's services, Xcode, iOS, or third-party forks should be sent to their respective maintainers unless Camenya is directly responsible.

## Support window

Only the current `main` branch is considered for security fixes. Maintenance is best effort: the project does not promise acknowledgement or remediation times. Please allow maintainers a reasonable opportunity to investigate before public disclosure.
