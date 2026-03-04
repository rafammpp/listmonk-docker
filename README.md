# Listmonk Docker (Amazon SES + Cloudflare) with GDPR focus

Self-hosted stack to run [listmonk](https://listmonk.app) on a VPS, send email through Amazon SES, and publish behind Cloudflare with strict TLS.

> Note: this repository supports GDPR technical controls, but it is not legal advice.

## Architecture

- **Server:** Any VPS provider (EU datacenter recommended).
- **Application:** `listmonk`.
- **Database:** PostgreSQL 14 in an internal Docker network.
- **Outbound mail:** Amazon SES via SMTP (`STARTTLS`, port `587`).
- **Edge:** Cloudflare (`Full (Strict)`) + Nginx.

## What this repository improves

- `db` and `app` are not publicly exposed (`127.0.0.1:9000` only on host).
- Nginx enforces HTTP→HTTPS redirect and security headers.
- Runtime variables are centralized in `.env`.

## 1) Server preparation

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
```

Create persistent folders:

```bash
mkdir -p data/db uploads certs
```

## 2) Secret and app configuration

1. Copy environment variables:
   ```bash
   cp .env.example .env
   ```
2. Edit `.env` and set long random passwords/secrets.
3. Start the stack. listmonk will read all required runtime configuration from environment variables (`LISTMONK_*`).

### Environment variables reference

| Variable | Required | Purpose |
|---|---|---|
| `TZ` | Yes | Container timezone for logs and runtime. |
| `LISTMONK_DOMAIN` | Yes | Public domain used to access listmonk (documentation/reference value). |
| `DB_USER` | Yes | PostgreSQL username used by listmonk. |
| `DB_PASSWORD` | Yes | PostgreSQL password. Use a long random value. |
| `DB_NAME` | Yes | PostgreSQL database name for listmonk. |
| `LISTMONK_ADMIN_USER` | Optional | Super Admin username for one-time bootstrap only. |
| `LISTMONK_ADMIN_PASSWORD` | Optional | Super Admin password for one-time bootstrap only. |

For better security, keep `LISTMONK_ADMIN_USER` and `LISTMONK_ADMIN_PASSWORD` empty in `.env` and set them only during first startup:

```bash
LISTMONK_ADMIN_USER=admin LISTMONK_ADMIN_PASSWORD='change-me' docker compose up -d
```

After first login, unset/remove these two variables.

## 3) TLS with Cloudflare Origin Certificate

1. In Cloudflare, generate an **Origin Certificate** for your subdomain (for example `news.example.com`).
2. Save files as:
   - `certs/cert.pem`
   - `certs/key.pem`
3. Set Cloudflare SSL/TLS mode to **Full (Strict)**.

## 4) Amazon SES (EU region recommended)

- Use an EU SMTP endpoint (for example `email-smtp.eu-west-1.amazonaws.com`).
- Create SES SMTP credentials (not direct IAM access keys).
- Verify domain/sender and publish SPF, DKIM, and DMARC.
- In listmonk UI, configure SMTP with:
   - Host: `email-smtp.eu-west-1.amazonaws.com`
   - Port: `587`
   - Encryption: `STARTTLS`
   - Auth: `LOGIN`
   - Username/Password: your SES SMTP credentials

## 5) Start services

```bash
docker compose up -d
docker compose logs -f app
```

Access: `https://your-subdomain`

## First-run checklist

- DNS is proxied through Cloudflare and points to your server.
- Cloudflare SSL/TLS mode is set to **Full (Strict)**.
- You can log in to listmonk and create/update the Super Admin account.
- SMTP is configured in `Admin -> Settings -> SMTP` with Amazon SES (`STARTTLS`, port `587`).
- A test campaign to your own inbox is sent successfully and headers show SPF/DKIM/DMARC pass.

## Minimum GDPR operations checklist

- Enable **double opt-in** in listmonk.
- Keep consent records (timestamp, source, and list).
- Publish privacy notice and legal basis for processing.
- Sign DPAs with processors/sub-processors (hosting provider, AWS).
- Implement subscriber deletion workflow (right to erasure).
- Minimize tracking when not strictly necessary.

## Additional recommended security

- Host firewall: open only `22`, `80`, and `443`.
- SSH keys only (disable password login).
- Encrypted backups and restore testing (DB + `uploads`).
- Regular updates: `docker compose pull && docker compose up -d`.

## Useful commands

```bash
# Status
docker compose ps

# Restart services
docker compose restart

# Basic PostgreSQL backup
docker compose exec -T db pg_dump -U "$DB_USER" "$DB_NAME" > backup.sql
```