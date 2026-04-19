# Third-Party Notices

This repository builds and runs on third-party software. Their own licenses and terms apply to those components.

## Components

- Nginx base image (`nginx:alpine`)
  - Upstream: https://hub.docker.com/_/nginx
  - License: see upstream image/project documentation
- Certbot package (installed via Alpine package manager)
  - Upstream: https://certbot.eff.org/
  - License: see upstream project documentation
- Tini package (installed via Alpine package manager)
  - Upstream: https://github.com/krallin/tini
  - License: see upstream project documentation
- Alpine Linux packages (installed with `apk`)
  - License: see Alpine package metadata for each package

## Notes

- This repository source code is licensed under MIT (see `LICENSE`).
- MIT in this repository does not relicense nginx, certbot, tini, or Alpine packages.
- Third-party names and trademarks belong to their respective owners.
