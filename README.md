# Listmonk Docker with GDPR-focused defaults

Self-hosted `listmonk` behind Nginx, with PostgreSQL, encrypted backups to Cloudflare R2, and a setup flow intended to stay simple.

> This repository helps with technical GDPR measures, but it is not legal advice.

## Prerequisites

Before you start, have these ready:

- a Debian/Ubuntu VPS in Europe with sudo access
- a domain or subdomain managed in Cloudflare, pointing to that VPS
- a Cloudflare Origin Certificate for that domain/subdomain:
   - `certs/cert.pem`
   - `certs/key.pem`
- a Cloudflare R2 bucket
- an R2 Lifecycle Rule configured for remote backup retention
- an R2 access key pair with permission to read/write that bucket

`setup-host.sh` can generate an `age` backup keypair for you. If you already have one, copy [secrets/secrets.env.example](secrets/secrets.env.example) to `secrets/secrets.env` and put it there before running setup.

## What this stack does

- `listmonk` only listens on `127.0.0.1:9000`
- PostgreSQL stays on an internal Docker network
- Nginx terminates HTTPS and adds basic security headers
- backups are encrypted before upload to R2
- by default the server stores only the `age` public key used for backup encryption
- runtime config is split into two files:
  - `.env` for normal configuration
  - `secrets/secrets.env` for secrets

## Files you need

### 1. Normal configuration

Copy [.env.example](.env.example) to `.env` and edit it.

Variables kept in `.env`:

- `TZ`
- `LISTMONK_DOMAIN`
- `BACKUP_RETENTION_DAYS`
- `BACKUP_SCHEDULE`
- `R2_BUCKET`
- `R2_ENDPOINT`
- `R2_PREFIX`

### 2. Secrets

Copy [secrets/secrets.env.example](secrets/secrets.env.example) to `secrets/secrets.env` and fill it in.

Variables kept in `secrets/secrets.env`:

- `POSTGRES_PASSWORD`
- `BACKUP_AGE_PUBLIC_KEY`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`

### Backup `age` keys

If `BACKUP_AGE_PUBLIC_KEY` is missing, [scripts/setup-host.sh](scripts/setup-host.sh) generates a new `age` keypair, shows both keys once, saves the public key to [secrets/secrets.env](secrets/secrets.env), and tells you to store the secret key safely.

If you already have an `age` keypair, put only the public key in `BACKUP_AGE_PUBLIC_KEY` in [secrets/secrets.env](secrets/secrets.env) before running setup. The script validates it and uses it as-is.

You can also generate the keypair yourself:

```bash
age-keygen -o listmonk-backup.agekey
age-keygen -y listmonk-backup.agekey
```

- save the line starting with `age1...` as `BACKUP_AGE_PUBLIC_KEY`
- save the line starting with `AGE-SECRET-KEY-1...` in your password manager or another safe place
- do not store the secret key in [secrets/secrets.env](secrets/secrets.env) or anywhere else on the server

The setup script generates temporary first-login credentials automatically and passes them only to the initial `docker compose up -d`. They are not written to `.env` or `secrets/secrets.env`.

### 3. TLS certificate

Put your Cloudflare Origin certificate files here:

- `certs/cert.pem`
- `certs/key.pem`

Use Cloudflare SSL/TLS mode `Full (Strict)`.

## Host setup

For a fresh Debian/Ubuntu host:

```bash
sudo ./scripts/setup-host.sh
```

The script:

- installs Docker, Compose, UFW, OpenSSL, `age`, curl and unattended security updates
- creates `data/`, `uploads/`, `backups/`, `secrets/` and `certs/`
- reads existing `.env`, `secrets/secrets.env` and `certs/` if they are already there
- asks only for missing values
- generates an `age` backup keypair if one is not already configured and shows it once so you can save it
- can enable automatic security updates with `unattended-upgrades`
- can enable a basic firewall for SSH, HTTP and HTTPS
- starts the Docker stack automatically at the end
- generates temporary bootstrap admin credentials for first login and prints them for immediate login without storing them in a file
- stores `BACKUP_AGE_PUBLIC_KEY` on the server and never stores the `age` secret key

## Start the stack manually

`setup-host.sh` starts the stack automatically at the end. Use this when you want to start it manually later:

```bash
docker compose up -d
docker compose logs -f app
```

Access:

- `https://your-domain`

## First login checklist

- log in to `listmonk`
- create your real admin user immediately
- configure Amazon SES in `Admin -> Settings -> SMTP`
- send a test message to yourself
- enable double opt-in in `listmonk`

## TODO

- document the full `listmonk` + Amazon SES configuration flow

## Backups

Automatic backups are run by the `backup` service.

Manual backup:

```bash
./scripts/backup-to-r2.sh
```

What happens:

- PostgreSQL is dumped
- the dump is compressed and encrypted with `age` using `BACKUP_AGE_PUBLIC_KEY`
- the encrypted file and checksum are uploaded to R2
- local backups older than `BACKUP_RETENTION_DAYS` are removed

Remote retention should be configured with an R2 Lifecycle Rule.

## Restore

List available backups:

```bash
./scripts/restore-from-r2.sh --list
```

Restore the latest backup:

```bash
./scripts/restore-from-r2.sh
```

Restore a specific backup:

```bash
./scripts/restore-from-r2.sh <backup-key>
```

The host restore script asks for confirmation, then prompts for the `age` secret key without echoing it, and stops `app` during restore unless you use `--no-stop`.

## Migration

To move the stack to another server:

1. `git clone` the repository on the new host
2. copy these items from the old host:
   - `.env`
   - `secrets/secrets.env`
   - `certs/`
3. run:
   ```bash
   sudo ./scripts/setup-host.sh
   ```
4. restore the database from R2 if needed:
   ```bash
   ./scripts/restore-from-r2.sh
   ```

If `.env`, `secrets/secrets.env` and `certs/` are already present, the setup script should only ask for whatever is still missing.

## Minimal GDPR operational reminders

This repository does not complete GDPR compliance on its own. At minimum, you still need to handle:

- double opt-in
- proof of consent
- privacy notice
- retention policy
- deletion workflow
- DPAs with OVH, AWS and Cloudflare

## Useful commands

```bash
docker compose ps
docker compose restart
./scripts/backup-to-r2.sh
./scripts/restore-from-r2.sh --list
./scripts/restore-from-r2.sh
```
