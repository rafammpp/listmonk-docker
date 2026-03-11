#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"
SECRETS_DIR="$ROOT_DIR/secrets"
SECRETS_FILE="$SECRETS_DIR/secrets.env"
CERTS_DIR="$ROOT_DIR/certs"
CERT_FILE="$CERTS_DIR/cert.pem"
KEY_FILE="$CERTS_DIR/key.pem"

TZ_VALUE=
LISTMONK_DOMAIN_VALUE=
BACKUP_RETENTION_DAYS_VALUE=
BACKUP_SCHEDULE_VALUE=
BACKUP_AGE_PUBLIC_KEY_VALUE=
R2_BUCKET_VALUE=
R2_ENDPOINT_VALUE=
R2_PREFIX_VALUE=
POSTGRES_PASSWORD_VALUE=
R2_ACCESS_KEY_ID_VALUE=
R2_SECRET_ACCESS_KEY_VALUE=

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "Run this script with sudo or as root." >&2
        exit 1
    fi
}

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "This script currently supports Debian/Ubuntu systems with apt-get." >&2
        exit 1
    fi
}

require_docker_compose() {
    if ! docker compose version >/dev/null 2>&1; then
        echo "docker compose is required after installation." >&2
        exit 1
    fi
}

read_env_value() {
    local file_path=$1
    local key=$2
    local line

    [[ -f "$file_path" ]] || return 0
    line=$(grep -E "^${key}=" "$file_path" | tail -n 1 || true)
    if [[ -n "$line" ]]; then
        printf '%s' "${line#*=}"
    fi
}

load_existing_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        return
    fi

    TZ_VALUE=$(read_env_value "$ENV_FILE" TZ)
    LISTMONK_DOMAIN_VALUE=$(read_env_value "$ENV_FILE" LISTMONK_DOMAIN)
    BACKUP_RETENTION_DAYS_VALUE=$(read_env_value "$ENV_FILE" BACKUP_RETENTION_DAYS)
    BACKUP_SCHEDULE_VALUE=$(read_env_value "$ENV_FILE" BACKUP_SCHEDULE)
    R2_BUCKET_VALUE=$(read_env_value "$ENV_FILE" R2_BUCKET)
    R2_ENDPOINT_VALUE=$(read_env_value "$ENV_FILE" R2_ENDPOINT)
    R2_PREFIX_VALUE=$(read_env_value "$ENV_FILE" R2_PREFIX)
}

load_existing_secrets() {
    if [[ ! -f "$SECRETS_FILE" ]]; then
        return
    fi

    POSTGRES_PASSWORD_VALUE=$(read_env_value "$SECRETS_FILE" POSTGRES_PASSWORD)
    BACKUP_AGE_PUBLIC_KEY_VALUE=$(read_env_value "$SECRETS_FILE" BACKUP_AGE_PUBLIC_KEY)
    R2_ACCESS_KEY_ID_VALUE=$(read_env_value "$SECRETS_FILE" R2_ACCESS_KEY_ID)
    R2_SECRET_ACCESS_KEY_VALUE=$(read_env_value "$SECRETS_FILE" R2_SECRET_ACCESS_KEY)
}

resolve_value() {
    local var_name=$1
    local prompt_text=$2
    local default_value=${3:-}
    local current_value

    eval "current_value=\${$var_name:-}"
    if [[ -n "$current_value" ]]; then
        return
    fi

    prompt_default "$var_name" "$prompt_text" "$default_value"
}

prompt_default() {
    local var_name=$1
    local prompt_text=$2
    local default_value=${3:-}
    local input

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt_text [$default_value]: " input
        printf -v "$var_name" '%s' "${input:-$default_value}"
    else
        while true; do
            read -r -p "$prompt_text: " input
            if [[ -n "$input" ]]; then
                printf -v "$var_name" '%s' "$input"
                break
            fi
            echo "This value cannot be empty."
        done
    fi
}

validate_age_public_key() {
    local public_key=$1

    [[ -n "$public_key" ]] || return 1
    printf '' | age -r "$public_key" >/dev/null 2>&1
}

generate_age_keypair() {
    local temp_dir temp_file public_key secret_key

    temp_dir=$(mktemp -d)
    temp_file="$temp_dir/agekey.txt"

    age-keygen -o "$temp_file" >/dev/null 2>&1

    public_key=$(sed -n 's/^# public key: //p' "$temp_file" | tail -n 1)
    if [[ -z "$public_key" ]]; then
        public_key=$(age-keygen -y "$temp_file" 2>/dev/null || true)
    fi
    secret_key=$(grep -E '^AGE-SECRET-KEY-1' "$temp_file" | tail -n 1 || true)

    rm -f "$temp_file"
    rmdir "$temp_dir"

    [[ -n "$public_key" && -n "$secret_key" ]] || return 1
    printf '%s\n%s\n' "$public_key" "$secret_key"
}

show_generated_age_keypair() {
    local public_key=$1
    local secret_key=$2
    local saved_key

    echo
    echo "==> Generated a new age backup keypair"
    echo "Save the secret key outside this server now. It is required to restore backups."
    echo "The setup script will store only the public key in $SECRETS_FILE."
    echo
    echo "Public key (will be saved as BACKUP_AGE_PUBLIC_KEY):"
    echo "  $public_key"
    echo
    echo "Secret key (save this in your password manager or another safe place):"
    echo "  $secret_key"
    echo

    prompt_yes_no saved_key "Have you saved the age secret key outside this server?" "n"
    if [[ "$saved_key" != "yes" ]]; then
        echo "Save the age secret key and rerun the setup." >&2
        exit 1
    fi
}

prompt_secret() {
    local var_name=$1
    local prompt_text=$2
    local allow_generate=${3:-false}
    local input

    while true; do
        read -r -s -p "$prompt_text" input
        echo
        if [[ -z "$input" && "$allow_generate" == "true" ]]; then
            input=$(openssl rand -base64 48)
            echo "Generated random value."
        fi
        if [[ -n "$input" ]]; then
            printf -v "$var_name" '%s' "$input"
            break
        fi
        echo "This value cannot be empty."
    done
}

prompt_yes_no() {
    local var_name=$1
    local prompt_text=$2
    local default_value=${3:-y}
    local input

    while true; do
        read -r -p "$prompt_text [${default_value^^}/$([[ "$default_value" == "y" ]] && echo n || echo y)]: " input
        input=${input:-$default_value}
        case "$input" in
            y|Y|yes|YES)
                printf -v "$var_name" '%s' "yes"
                return
                ;;
            n|N|no|NO)
                printf -v "$var_name" '%s' "no"
                return
                ;;
        esac
        echo "Please answer yes or no."
    done
}

generate_temp_admin_credentials() {
    TEMP_ADMIN_USER="bootstrap-$(openssl rand -hex 4)"
    TEMP_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
}

write_secrets_file() {
    local postgres_password=$1
    local backup_age_public_key=$2
    local r2_access_key_id=$3
    local r2_secret_access_key=$4

    install -m 700 -d "$SECRETS_DIR"
    cat > "$SECRETS_FILE" <<EOF
POSTGRES_PASSWORD=$postgres_password
BACKUP_AGE_PUBLIC_KEY=$backup_age_public_key
R2_ACCESS_KEY_ID=$r2_access_key_id
R2_SECRET_ACCESS_KEY=$r2_secret_access_key
EOF
    chmod 600 "$SECRETS_FILE"
}

maybe_capture_pem() {
    local label=$1
    local file_path=$2
    local should_capture
    local line

    if [[ -s "$file_path" ]]; then
        echo "$label already present at $file_path."
        return
    fi

    prompt_yes_no should_capture "Do you want to paste the $label now? End with a line containing __EOF__." "n"
    if [[ "$should_capture" != "yes" ]]; then
        return
    fi

    install -m 700 -d "$CERTS_DIR"
    : > "$file_path"
    echo "Paste the $label. Finish with __EOF__ on its own line."
    while IFS= read -r line; do
        [[ "$line" == "__EOF__" ]] && break
        printf '%s\n' "$line" >> "$file_path"
    done
    chmod 600 "$file_path"
}

ensure_tls_files() {
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        echo "Missing TLS files. Ensure both $CERT_FILE and $KEY_FILE exist before continuing." >&2
        exit 1
    fi
}

configure_firewall() {
    local enable_firewall ssh_port

    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo "UFW is already active."
        return
    fi

    prompt_yes_no enable_firewall "Configure UFW to allow SSH, HTTP and HTTPS?" "y"
    if [[ "$enable_firewall" != "yes" ]]; then
        return
    fi

    prompt_default ssh_port "SSH port to allow through the firewall" "22"
    ufw allow "${ssh_port}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
}

configure_auto_updates() {
    local enable_auto_updates

    prompt_yes_no enable_auto_updates "Enable automatic security updates with unattended-upgrades?" "y"
    if [[ "$enable_auto_updates" != "yes" ]]; then
        return
    fi

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
    echo "Automatic security updates enabled."
}

maybe_add_docker_group() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        usermod -aG docker "$SUDO_USER" || true
        echo "Added $SUDO_USER to the docker group. A new login session may be required."
    fi
}

write_env_file() {
    local tz=$1
    local domain=$2
    local backup_retention_days=$3
    local backup_schedule=$4
    local r2_bucket=$5
    local r2_endpoint=$6
    local r2_prefix=$7

    cat > "$ENV_FILE" <<EOF
TZ=$tz
LISTMONK_DOMAIN=$domain
BACKUP_RETENTION_DAYS=$backup_retention_days
BACKUP_SCHEDULE=$backup_schedule
R2_BUCKET=$r2_bucket
R2_ENDPOINT=$r2_endpoint
R2_PREFIX=$r2_prefix
EOF
    chmod 600 "$ENV_FILE"
}

main() {
    local tz domain backup_retention_days backup_schedule backup_age_public_key r2_bucket r2_endpoint r2_prefix
    local postgres_password r2_access_key_id r2_secret_access_key
    local generated_age_keypair generated_backup_age_secret_key

    require_root
    require_apt
    load_existing_env
    load_existing_secrets

    echo "==> Installing host packages"
    # https://docs.docker.com/engine/install/debian/#install-using-the-repository
    # Add Docker's official GPG key:
    apt update
    apt install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ufw openssl age ca-certificates curl unattended-upgrades apt-listchanges
    systemctl enable --now docker
    maybe_add_docker_group

    echo "==> Creating local directories"
    install -m 700 -d "$ROOT_DIR/data/db" "$ROOT_DIR/uploads" "$ROOT_DIR/backups" "$SECRETS_DIR" "$CERTS_DIR"

    echo "==> Collecting runtime configuration"
    tz=$TZ_VALUE
    domain=$LISTMONK_DOMAIN_VALUE
    backup_retention_days=$BACKUP_RETENTION_DAYS_VALUE
    backup_schedule=$BACKUP_SCHEDULE_VALUE
    backup_age_public_key=$BACKUP_AGE_PUBLIC_KEY_VALUE
    r2_bucket=$R2_BUCKET_VALUE
    r2_endpoint=$R2_ENDPOINT_VALUE
    r2_prefix=$R2_PREFIX_VALUE
    postgres_password=$POSTGRES_PASSWORD_VALUE
    r2_access_key_id=$R2_ACCESS_KEY_ID_VALUE
    r2_secret_access_key=$R2_SECRET_ACCESS_KEY_VALUE

    resolve_value tz "Timezone" "Europe/Madrid"
    resolve_value domain "Public domain for listmonk" "news.example.com"
    resolve_value backup_retention_days "Days to keep encrypted local backups" "7"
    resolve_value backup_schedule "Backup schedule (cron expression)" "0 3 * * *"
    if [[ -n "$backup_age_public_key" ]]; then
        if ! validate_age_public_key "$backup_age_public_key"; then
            echo "Existing BACKUP_AGE_PUBLIC_KEY in $SECRETS_FILE is not valid." >&2
            exit 1
        fi
        echo "Backup age public key already present in $SECRETS_FILE."
    fi

    if [[ -z "$backup_age_public_key" ]]; then
        if ! generated_age_keypair=$(generate_age_keypair); then
            echo "Failed to generate an age backup keypair." >&2
            exit 1
        fi
        backup_age_public_key=$(printf '%s\n' "$generated_age_keypair" | sed -n '1p')
        generated_backup_age_secret_key=$(printf '%s\n' "$generated_age_keypair" | sed -n '2p')
        show_generated_age_keypair "$backup_age_public_key" "$generated_backup_age_secret_key"
    fi

    resolve_value r2_bucket "Cloudflare R2 bucket name"
    resolve_value r2_endpoint "Cloudflare R2 S3 endpoint (https://<account-id>.r2.cloudflarestorage.com)"
    resolve_value r2_prefix "R2 prefix/folder" "listmonk"

    echo "==> Collecting secrets"
    if [[ -n "$postgres_password" ]]; then
        echo "Database password already present in $SECRETS_FILE."
    else
        prompt_secret postgres_password "Database password (leave blank to auto-generate): " true
    fi

    if [[ -n "$r2_access_key_id" ]]; then
        echo "Cloudflare R2 access key ID already present in $SECRETS_FILE."
    else
        prompt_secret r2_access_key_id "Cloudflare R2 access key ID: " false
    fi

    if [[ -n "$r2_secret_access_key" ]]; then
        echo "Cloudflare R2 secret access key already present in $SECRETS_FILE."
    else
        prompt_secret r2_secret_access_key "Cloudflare R2 secret access key: " false
    fi

    write_env_file "$tz" "$domain" "$backup_retention_days" "$backup_schedule" "$r2_bucket" "$r2_endpoint" "$r2_prefix"
    echo "Wrote $ENV_FILE"
    write_secrets_file "$postgres_password" "$backup_age_public_key" "$r2_access_key_id" "$r2_secret_access_key"
    echo "Wrote $SECRETS_FILE"

    maybe_capture_pem "Cloudflare Origin certificate" "$CERT_FILE"
    maybe_capture_pem "Cloudflare Origin private key" "$KEY_FILE"

    configure_auto_updates
    configure_firewall
    ensure_tls_files
    require_docker_compose

    echo "==> Starting Docker services"
    generate_temp_admin_credentials
    echo "Generated temporary bootstrap admin credentials for first login."
    (
        cd "$ROOT_DIR" && \
        docker compose up -d db backup && \
        LISTMONK_ADMIN_USER="$TEMP_ADMIN_USER" \
        LISTMONK_ADMIN_PASSWORD="$TEMP_ADMIN_PASSWORD" \
        docker compose up -d --force-recreate app && \
        docker compose up -d nginx
    )

    echo
    echo "Host setup complete."
    echo "Next steps:"
    echo "  1. Review $ENV_FILE"
    echo "  2. Review $SECRETS_FILE"
    echo "  3. Log in to your listmonk"
    echo ""
    echo "Temporary first-login credentials:"
    echo "  URL: https://$domain"
    echo "  Username: $TEMP_ADMIN_USER"
    echo "  Password: $TEMP_ADMIN_PASSWORD"
    echo ""
    echo "Create your real admin user immediately after login."
    echo "These temporary credentials were not written to any file."
    if [[ -n "$generated_backup_age_secret_key" ]]; then
        echo "A new age secret key was generated and shown above. It was not stored on the server."
    fi
    echo "Restore will ask for the age secret key when needed."
    echo "  4. Test a backup with: ./scripts/backup-to-r2.sh"
}

main "$@"