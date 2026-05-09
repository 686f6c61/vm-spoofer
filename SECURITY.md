# Security Policy

## Supported Use

This project is intended for authorized lab, QA, validation, and integration work on virtualized environments owned or explicitly approved by the operator.

Do not use it against third-party systems, shared infrastructure, or client environments without written authorization and a rollback plan.

## Reporting Issues

Report security issues privately to the repository maintainer. Include:

- Affected script and operating system.
- Exact VirtualBox version.
- Steps to reproduce.
- Expected and actual behavior.
- Whether the issue can leave remote access, USB filters, networking, or VM metadata in an unsafe state.

Avoid posting sensitive client data, VM names, serial numbers, MAC addresses, or screenshots that include internal infrastructure details.

## Operational Safety

Before applying changes to a client VM:

- Take a VirtualBox snapshot or export the appliance.
- Keep the generated `backups/` folder until validation is complete.
- Review VRDE/RDP settings before network exposure.
- Run restoration on a clone before using it on a production-like image.
