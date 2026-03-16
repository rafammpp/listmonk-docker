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

`setup-host.sh` can generate an `age` backup keypair for you. If you already have one, you can optionally pre-create [secrets/secrets.env](secrets/secrets.env) from [secrets/secrets.env.example](secrets/secrets.env.example) and put only `BACKUP_AGE_PUBLIC_KEY` there before running setup.

## What this stack does

- `listmonk` only listens on `127.0.0.1:9000`
- PostgreSQL stays on an internal Docker network
- Nginx terminates HTTPS and adds basic security headers
- backups are encrypted before upload to R2
- by default the server stores only the `age` public key used for backup encryption
- runtime config is split into two files:
  - `.env` for normal configuration
  - `secrets/secrets.env` for secrets

## Host setup

For a fresh Debian/Ubuntu host:

```bash
sudo ./scripts/setup-host.sh
```

The script:

- installs Docker, Compose, UFW, `fail2ban`, OpenSSL, `age`, curl and unattended security updates
- creates `data/`, `uploads/`, `backups/`, `secrets/` and `certs/`
- reads existing `.env`, `secrets/secrets.env` and `certs/` if they are already there
- asks only for missing values
- can let you paste the Cloudflare Origin certificate and private key during setup if the `certs/` files are missing
- generates an `age` backup keypair if one is not already configured and shows it once so you can save it
- can enable automatic security updates with `unattended-upgrades`
- can enable a basic firewall for SSH, HTTP and HTTPS
- can disable SSH login for `root` by writing an `sshd_config.d` drop-in
- can enable `fail2ban` protection for SSH brute-force attempts
- starts the Docker stack automatically at the end
- generates temporary bootstrap admin credentials for first login and prints them for immediate login without storing them in a file
- stores `BACKUP_AGE_PUBLIC_KEY` on the server and never stores the `age` secret key

You do not need to create `.env`, `secrets/secrets.env`, `certs/cert.pem`, or `certs/key.pem` before running the setup script.

### Optional pre-seeding before setup

If you prefer, you can still create these files in advance. The script will reuse them and ask only for anything that is still missing.

Typical values in `.env`:

- `TZ`
- `LISTMONK_DOMAIN`
- `BACKUP_RETENTION_DAYS`
- `BACKUP_SCHEDULE`
- `R2_BUCKET`
- `R2_ENDPOINT`
- `R2_PREFIX` (typically `backups` for paths like `R2_BUCKET/backups/db-...sql.gz.age`)

Typical values in `secrets/secrets.env`:

- `POSTGRES_PASSWORD`
- `BACKUP_AGE_PUBLIC_KEY`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`

If you already have your Cloudflare Origin certificate files, place them here before running setup:

- `certs/cert.pem`
- `certs/key.pem`

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

### Cloudflare and TLS certificate

Use Cloudflare SSL/TLS mode `Full (Strict)`.

Disable `cache everything` rule for the domain/subdomain, if you have it. It interferes with the admin interface.

The setup script generates temporary first-login credentials automatically and passes them only to the initial `docker compose up -d`. They are not written to `.env` or `secrets/secrets.env`.

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

## Listmonk + Amazon SES configuration
Login on AWS console on an eu region, and go to SES service. They will guide you through the process of verifying your domain, setting up DKIM and SPF records, and requesting production access if needed. Once your SES setup is complete, you can use the SMTP credentials provided by AWS in the `listmonk` admin settings to send emails.

On your listmonk admin dashboard, navigate to `Settings -> SMTP` and enter the following details:
- SMTP Host: `email-smtp.<region>.amazonaws.com` (replace with the host provided by AWS SES for your region)
- SMTP Port: `587`
- Auth protocol: `LOGIN`
- SMTP Username: Your AWS SES SMTP username (not the same as your AWS access key)
- SMTP Password: Your AWS SES SMTP password (not the same as your AWS secret key)
- TLS: `STARTTLS`

After entering these details, save the settings and send a test email to ensure that everything is configured correctly. If the test email is successful, your `listmonk` instance is now set up to send emails through Amazon SES.

### Bounce handling
To handle bounces and complaints from Amazon SES, you can set up an SNS topic and subscribe to it with an email address or an HTTP endpoint. This way, you can receive notifications about bounces and complaints, which is crucial for maintaining a good sender reputation and ensuring that your emails are delivered successfully.
Follow this guide from listmonk docs: https://listmonk.app/docs/bounces/#amazon-simple-email-service-ses

#### Troubleshooting repeated SES simulator tests

If SES webhooks reach `/webhooks/service/ses` and return `200`, but no new bounce appears in `listmonk`, check the existing bounce history for that subscriber before blaming Cloudflare.

`listmonk` counts existing bounces per subscriber and type (`soft`, `hard`, `complaint`). Once the configured threshold in `Settings -> Bounces` has already been reached, or the subscriber is already `blocklisted`, later webhook deliveries can still return `200` without inserting a new bounce row. In that situation, the campaign may continue to show `0` new bounces even though SNS delivered the webhook successfully.

This commonly happens when testing multiple times with Amazon SES simulator addresses such as:

- `ooto@simulator.amazonses.com`
- `bounce@simulator.amazonses.com`
- `complaint@simulator.amazonses.com`

Before repeating those tests, delete the old bounce records for the simulator subscribers or temporarily raise the bounce thresholds in `Settings -> Bounces`.

## Backups

Automatic backups are run by the `backup` service.

Manual backup:

```bash
./scripts/backup-to-r2.sh
```

What happens:

- PostgreSQL is dumped
- the dump is compressed and encrypted with `age` using `BACKUP_AGE_PUBLIC_KEY`
- the encrypted file and checksum are uploaded to R2 under `R2_BUCKET/R2_PREFIX/`
- local backups older than `BACKUP_RETENTION_DAYS` are removed

By default, new backups use object names like `backups/db-20260316T030000Z.sql.gz.age` and `backups/db-20260316T030000Z.sql.gz.age.sha256` inside the bucket.

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
