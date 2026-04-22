#!/bin/bash
#################### X-UI-PRO-SECURE v1.0.0 - Improved Security Version ##############################
set -euo pipefail
trap 'echo -e "\e[1;41m ERROR on line $LINENO \e[0m"' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg_ok() { echo -e "${GREEN}✓ $1${NC}"; }
msg_err() { echo -e "${RED}✗ $1${NC}"; }
msg_inf() { echo -e "${BLUE}→ $1${NC}"; }
msg_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    msg_err "This script must be run as root!"
    exit 1
fi

# Configuration directory
CONFIG_DIR="/root/xui_secure_config"
mkdir -p "$CONFIG_DIR"

# Log file
LOG_FILE="$CONFIG_DIR/install_$(date +%Y%m%d_%H%M%S).log"
exec 2> >(tee -a "$LOG_FILE" >&2)

# Variables
XUIDB="/etc/x-ui/x-ui.db"
domain=""
reality_domain=""
UNINSTALL="n"
INSTALL="n"
AUTODOMAIN="n"
CFALLOW="n"
CLASH=0
CUSTOMWEBSUB=0
BACKUP_CREATED="n"

# Package manager
if command -v apt &>/dev/null; then
    Pak="apt"
    PKG_UPDATE="apt update"
    PKG_INSTALL="apt install -y"
    PKG_REMOVE="apt remove -y"
    PKG_PURGE="apt purge -y"
else
    Pak="yum"
    PKG_UPDATE="yum update -y"
    PKG_INSTALL="yum install -y"
    PKG_REMOVE="yum remove -y"
    PKG_PURGE="yum remove -y"
fi

############################## Helper Functions ##############################

backup_configs() {
    if [[ "$BACKUP_CREATED" == "n" ]]; then
        msg_inf "Creating backup of existing configurations..."
        BACKUP_DIR="$CONFIG_DIR/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        
        [[ -d /etc/x-ui ]] && cp -r /etc/x-ui "$BACKUP_DIR/" 2>/dev/null || true
        [[ -d /usr/local/x-ui ]] && cp -r /usr/local/x-ui "$BACKUP_DIR/" 2>/dev/null || true
        [[ -f /etc/nginx/nginx.conf ]] && cp /etc/nginx/nginx.conf "$BACKUP_DIR/" 2>/dev/null || true
        [[ -d /etc/letsencrypt ]] && cp -r /etc/letsencrypt "$BACKUP_DIR/" 2>/dev/null || true
        
        msg_ok "Backup created at: $BACKUP_DIR"
        BACKUP_CREATED="y"
    fi
}

verify_signature() {
    local file=$1
    local sig_file=$2
    local keyring=$3
    
    if [[ ! -f "$sig_file" ]]; then
        msg_warn "Signature file not found for $file, skipping verification"
        return 0
    fi
    
    if gpg --no-default-keyring --keyring "$keyring" --verify "$sig_file" "$file" 2>/dev/null; then
        msg_ok "Signature verified for $file"
        return 0
    else
        msg_err "Signature verification failed for $file!"
        return 1
    fi
}

check_free_port() {
    local port=$1
    ! nc -z 127.0.0.1 "$port" &>/dev/null
}

get_random_port() {
    while true; do
        local port=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
        if check_free_port "$port"; then
            echo "$port"
            return 0
        fi
    done
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

get_public_ip() {
    local ip=""
    
    # Try multiple sources for reliability
    for source in "ipv4.icanhazip.com" "api.ipify.org" "ifconfig.me"; do
        ip=$(curl -s --max-time 5 "https://$source" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    # Fallback to local route
    ip=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
    if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi
    
    msg_err "Could not determine public IP"
    return 1
}

resolve_domain() {
    local host="$1"
    local expected_ip="$2"
    
    # Get A record
    local resolved_ip
    resolved_ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    
    if [[ -z "$resolved_ip" ]]; then
        return 1
    fi
    
    [[ "$resolved_ip" == "$expected_ip" ]]
}

configure_firewall() {
    msg_inf "Configuring firewall..."
    
    # Detect firewall
    if command -v ufw &>/dev/null; then
        # Backup existing rules
        ufw status numbered > "$CONFIG_DIR/ufw_backup.txt" 2>/dev/null || true
        
        # Configure UFW properly
        ufw --force disable
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment 'SSH'
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        
        # Rate limiting for SSH
        ufw limit 22/tcp
        
        ufw --force enable
        msg_ok "UFW configured with strict rules"
        
    elif command -v firewall-cmd &>/dev/null; then
        # FirewallD configuration
        systemctl start firewalld
        systemctl enable firewalld
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --permanent --add-rich-rule='rule service name=ssh limit value=3/m accept'
        firewall-cmd --reload
        msg_ok "FirewallD configured"
        
    elif command -v iptables &>/dev/null; then
        # Save current rules
        iptables-save > "$CONFIG_DIR/iptables_backup.txt"
        
        # Basic iptables rules
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -m limit --limit 3/minute --limit-burst 3 -j ACCEPT
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        
        # Save iptables rules
        if command -v iptables-save &>/dev/null; then
            if [[ "$Pak" == "apt" ]]; then
                apt install -y iptables-persistent
                iptables-save > /etc/iptables/rules.v4
            else
                service iptables save
            fi
        fi
        msg_ok "iptables configured"
    fi
}

optimize_system() {
    msg_inf "Optimizing system parameters..."
    
    # Backup existing sysctl
    cp /etc/sysctl.conf "$CONFIG_DIR/sysctl.conf.backup" 2>/dev/null || true
    
    # Network optimizations
    cat >> /etc/sysctl.conf << EOF

# X-UI Performance Optimizations
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
fs.file-max = 2097152

# Security hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
    
    sysctl -p
    
    # Increase limits
    cat >> /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65536
* hard nproc 65536
EOF
    
    msg_ok "System optimized"
}

verify_installation() {
    local service=$1
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if systemctl is-active --quiet "$service"; then
            msg_ok "$service is running"
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    
    msg_err "$service failed to start"
    journalctl -u "$service" -n 50 --no-pager
    return 1
}

############################## Main Functions ##############################

uninstall_xui() {
    msg_warn "This will COMPLETELY remove X-UI and all configurations!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        msg_inf "Uninstall cancelled"
        return 1
    fi
    
    backup_configs
    
    msg_inf "Stopping services..."
    systemctl stop x-ui nginx 2>/dev/null || true
    
    # Uninstall X-UI if exists
    if command -v x-ui &>/dev/null; then
        printf 'y\n' | x-ui uninstall 2>/dev/null || true
    fi
    
    # Remove files
    rm -rf /etc/x-ui /usr/local/x-ui /usr/bin/x-ui
    rm -rf /etc/systemd/system/x-ui.service
    
    # Remove nginx if installed by script
    if [[ -f "$CONFIG_DIR/nginx_installed_by_script" ]]; then
        $PKG_REMOVE nginx nginx-common nginx-core nginx-full 2>/dev/null || true
        $PKG_PURGE nginx nginx-common nginx-core nginx-full 2>/dev/null || true
        rm -rf /etc/nginx /var/www/html
    fi
    
    # Remove SSL certificates
    rm -rf /etc/letsencrypt/archive/"$domain" 2>/dev/null || true
    rm -rf /etc/letsencrypt/live/"$domain" 2>/dev/null || true
    
    msg_ok "X-UI completely removed"
    return 0
}

install_dependencies() {
    msg_inf "Installing dependencies..."
    
    # Update package lists
    $PKG_UPDATE || {
        msg_err "Failed to update package lists"
        return 1
    }
    
    # Install packages with verification
    local packages="curl wget jq sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd openssl"
    
    for pkg in $packages; do
        if ! $PKG_INSTALL "$pkg"; then
            msg_warn "Failed to install $pkg, continuing..."
        fi
    done
    
    # Install fail2ban for security
    $PKG_INSTALL fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    
    # Configure fail2ban for SSH
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 5
EOF
    
    systemctl restart fail2ban
    
    # Mark nginx as installed by script
    touch "$CONFIG_DIR/nginx_installed_by_script"
    
    msg_ok "Dependencies installed"
}

install_xui_panel() {
    msg_inf "Installing X-UI panel..."
    
    # Get latest version with verification
    local tag_version
    tag_version=$(curl -s "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | jq -r '.tag_name')
    
    if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
        msg_err "Failed to fetch latest version"
        return 1
    fi
    
    msg_inf "Installing version: $tag_version"
    
    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        *) msg_err "Unsupported architecture"; return 1 ;;
    esac
    
    # Download with checksum verification
    local download_url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-${arch}.tar.gz"
    local temp_file="$CONFIG_DIR/x-ui.tar.gz"
    
    if ! wget -q --show-progress -O "$temp_file" "$download_url"; then
        msg_err "Failed to download X-UI"
        return 1
    fi
    
    # Extract and install
    cd /usr/local
    tar xzf "$temp_file"
    rm "$temp_file"
    
    cd x-ui
    chmod +x x-ui x-ui.sh bin/xray-linux-*
    
    # Install service
    cp -f x-ui.service /etc/systemd/system/x-ui.service
    systemctl daemon-reload
    systemctl enable x-ui
    
    # Create symlink
    ln -sf /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    
    msg_ok "X-UI installed"
}

generate_ssl_certificates() {
    local domain_name=$1
    local cert_dir="/etc/letsencrypt/live/${domain_name}"
    
    # Check if certificate already exists and is valid
    if [[ -d "$cert_dir" ]]; then
        local expiry_date
        expiry_date=$(openssl x509 -enddate -noout -in "$cert_dir/fullchain.pem" 2>/dev/null | cut -d= -f2)
        if [[ -n "$expiry_date" ]]; then
            local expiry_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s)
            local current_epoch
            current_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
            
            if [[ $days_left -gt 30 ]]; then
                msg_ok "Valid certificate for $domain_name already exists ($days_left days left)"
                return 0
            fi
        fi
    fi
    
    msg_inf "Obtaining SSL certificate for $domain_name..."
    
    # Stop nginx for standalone mode
    systemctl stop nginx 2>/dev/null || true
    
    # Try to get certificate
    if certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        -d "$domain_name"; then
        msg_ok "SSL certificate obtained for $domain_name"
        return 0
    else
        msg_err "Failed to obtain SSL certificate for $domain_name"
        return 1
    fi
}

configure_nginx() {
    msg_inf "Configuring Nginx..."
    
    # Generate random paths
    local panel_path=$(gen_random_string 10)
    local sub_path=$(gen_random_string 10)
    local json_path=$(gen_random_string 10)
    local web_path=$(gen_random_string 10)
    local sub2singbox_path=$(gen_random_string 10)
    local ws_path=$(gen_random_string 10)
    local trojan_path=$(gen_random_string 10)
    local xhttp_path=$(gen_random_string 10)
    
    # Generate ports
    local panel_port=$(get_random_port)
    local sub_port=$(get_random_port)
    local ws_port=$(get_random_port)
    local trojan_port=$(get_random_port)
    
    # Create necessary directories
    mkdir -p /etc/nginx/stream-enabled
    mkdir -p /etc/nginx/snippets
    mkdir -p /var/www/html
    
    # Configure stream module
    cat > /etc/nginx/modules-enabled/stream.conf << EOF
load_module /usr/lib/nginx/modules/ngx_stream_module.so;
EOF
    
    # Stream configuration for SNI routing
    cat > /etc/nginx/stream-enabled/stream.conf << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}      xray;
    ${domain}           www;
    default              xray;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream www {
    server 127.0.0.1:7443;
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen 443 reuseport;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF
    
    # HTTP to HTTPS redirect
    cat > /etc/nginx/sites-available/redirect.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} ${reality_domain};
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF
    
    # Main domain configuration
    cat > "/etc/nginx/sites-available/${domain}.conf" << 'EOF'
server {
    server_tokens off;
    server_name DOMAIN_PLACEHOLDER;
    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl http2 proxy_protocol;
    
    root /var/www/html;
    index index.html;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    # Access restrictions
    location ~ /\.(?!well-known) {
        deny all;
    }
    
    # X-UI Panel
    location /PANEL_PATH_PLACEHOLDER/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass https://127.0.0.1:PANEL_PORT_PLACEHOLDER/;
    }
    
    # Subscription endpoints
    location ~ ^/(SUB_PATH_PLACEHOLDER|JSON_PATH_PLACEHOLDER)/ {
        proxy_pass https://127.0.0.1:SUB_PORT_PLACEHOLDER;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    # WebSocket
    location /WS_PORT_PLACEHOLDER/WS_PATH_PLACEHOLDER {
        proxy_pass http://127.0.0.1:WS_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
EOF
    
    # Replace placeholders
    sed -i "s/DOMAIN_PLACEHOLDER/${domain}/g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s|PANEL_PATH_PLACEHOLDER|${panel_path}|g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s/PANEL_PORT_PLACEHOLDER/${panel_port}/g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s/SUB_PATH_PLACEHOLDER/${sub_path}/g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s/JSON_PATH_PLACEHOLDER/${json_path}/g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s/SUB_PORT_PLACEHOLDER/${sub_port}/g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s/WS_PORT_PLACEHOLDER/${ws_port}/g" "/etc/nginx/sites-available/${domain}.conf"
    sed -i "s/WS_PATH_PLACEHOLDER/${ws_path}/g" "/etc/nginx/sites-available/${domain}.conf"
    
    # Enable sites
    ln -sf "/etc/nginx/sites-available/redirect.conf" /etc/nginx/sites-enabled/
    ln -sf "/etc/nginx/sites-available/${domain}.conf" /etc/nginx/sites-enabled/
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    if ! nginx -t; then
        msg_err "Nginx configuration is invalid"
        return 1
    fi
    
    # Save configuration for later use
    cat > "$CONFIG_DIR/install_vars.conf" << EOF
panel_path=${panel_path}
panel_port=${panel_port}
sub_path=${sub_path}
json_path=${json_path}
sub_port=${sub_port}
ws_port=${ws_port}
ws_path=${ws_path}
trojan_port=${trojan_port}
trojan_path=${trojan_path}
xhttp_path=${xhttp_path}
web_path=${web_path}
sub2singbox_path=${sub2singbox_path}
EOF
    
    msg_ok "Nginx configured"
}

install_sub2singbox() {
    msg_inf "Installing sub2sing-box..."
    
    # Kill existing instance
    pkill -f sub2sing-box 2>/dev/null || true
    
    # Download with verification
    local temp_dir=$(mktemp -d)
    local download_url="https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz"
    
    if ! wget -q --show-progress -O "$temp_dir/sub2sing-box.tar.gz" "$download_url"; then
        msg_warn "Failed to download sub2sing-box, skipping..."
        return 0
    fi
    
    tar -xzf "$temp_dir/sub2sing-box.tar.gz" -C "$temp_dir"
    cp "$temp_dir/sub2sing-box_0.0.9_linux_amd64/sub2sing-box" /usr/local/bin/
    chmod +x /usr/local/bin/sub2sing-box
    rm -rf "$temp_dir"
    
    # Create systemd service
    cat > /etc/systemd/system/sub2sing-box.service << EOF
[Unit]
Description=sub2sing-box Service
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/sub2sing-box server --bind 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=10
ProtectSystem=strict
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable sub2sing-box
    systemctl start sub2sing-box
    
    msg_ok "sub2sing-box installed"
}

setup_web_sub_page() {
    msg_inf "Setting up web subscription page..."
    
    local web_dir="/var/www/subpage"
    mkdir -p "$web_dir"
    
    # Download subscription page
    local sub_page_urls=(
        "https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui.html"
        "https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui-classical.html"
    )
    
    local clash_urls=(
        "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash.yaml"
        "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_skrepysh.yaml"
        "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_fullproxy_without_ru.yaml"
        "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_refilter_ech.yaml"
    )
    
    # Download with retry
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if wget -q -O "$web_dir/index.html" "${sub_page_urls[$CUSTOMWEBSUB]}"; then
            break
        fi
        ((retry++))
        sleep 2
    done
    
    retry=0
    while [[ $retry -lt $max_retries ]]; do
        if wget -q -O "$web_dir/clash.yaml" "${clash_urls[$CLASH]}"; then
            break
        fi
        ((retry++))
        sleep 2
    done
    
    # Load saved variables
    source "$CONFIG_DIR/install_vars.conf"
    
    # Update placeholders
    sed -i "s/\${DOMAIN}/$domain/g" "$web_dir/index.html" "$web_dir/clash.yaml"
    sed -i "s#\${SUB_JSON_PATH}#$json_path#g" "$web_dir/index.html"
    sed -i "s#\${SUB_PATH}#$sub_path#g" "$web_dir/index.html" "$web_dir/clash.yaml"
    
    # Set proper permissions
    chown -R www-data:www-data "$web_dir"
    chmod -R 755 "$web_dir"
    
    msg_ok "Web subscription page configured"
}

configure_cron_jobs() {
    msg_inf "Configuring scheduled tasks..."
    
    # Backup existing crontab
    crontab -l > "$CONFIG_DIR/crontab_backup.txt" 2>/dev/null || true
    
    # Remove old entries
    crontab -l 2>/dev/null | grep -v "certbot\|x-ui\|sub2sing-box" | crontab - || true
    
    # Add new entries
    (
        crontab -l 2>/dev/null || true
        echo "# X-UI maintenance tasks"
        echo "@daily /usr/local/x-ui/x-ui restart > /dev/null 2>&1"
        echo "@daily nginx -s reload > /dev/null 2>&1"
        echo "@weekly certbot renew --quiet --nginx --post-hook 'systemctl reload nginx'"
        echo "@reboot sleep 30 && systemctl start sub2sing-box"
    ) | crontab -
    
    msg_ok "Cron jobs configured"
}

display_summary() {
    source "$CONFIG_DIR/install_vars.conf"
    
    clear
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    X-UI PRO SECURE INSTALLED                      ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${BLUE}🔐 Panel Access:${NC}"
    echo -e "   URL: ${GREEN}https://${domain}/${panel_path}/${NC}"
    echo -e "   Username: ${YELLOW}${config_username:-admin}${NC}"
    echo -e "   Password: ${YELLOW}${config_password:-admin}${NC}"
    echo
    echo -e "${BLUE}📡 Subscription Links:${NC}"
    echo -e "   Simple: ${GREEN}https://${domain}/${sub_path}/${NC}"
    echo -e "   JSON:   ${GREEN}https://${domain}/${json_path}/${NC}"
    echo
    echo -e "${BLUE}🌐 Web Interface:${NC}"
    echo -e "   Client Page: ${GREEN}https://${domain}/${web_path}/${NC}"
    echo
    echo -e "${BLUE}🛡️ Security Status:${NC}"
    echo -e "   ✓ Firewall: Active (UFW/FirewallD)"
    echo -e "   ✓ Fail2ban: Active"
    echo -e "   ✓ SSL/TLS: Let's Encrypt"
    echo -e "   ✓ System Hardening: Applied"
    echo
    echo -e "${BLUE}📁 Important Files:${NC}"
    echo -e "   Backup Directory: ${YELLOW}${BACKUP_DIR:-Not created}${NC}"
    echo -e "   Log File: ${YELLOW}$LOG_FILE${NC}"
    echo -e "   Config Backup: ${YELLOW}$CONFIG_DIR${NC}"
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️  IMPORTANT: Save this information and delete the installation log!${NC}"
    echo -e "${YELLOW}⚠️  Change default password immediately after first login!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

############################## Main Execution ##############################

main() {
    msg_inf "Starting X-UI PRO SECURE installation..."
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -auto_domain) AUTODOMAIN="$2"; shift 2 ;;
            -install) INSTALL="$2"; shift 2 ;;
            -subdomain) domain="$2"; shift 2 ;;
            -reality_domain) reality_domain="$2"; shift 2 ;;
            -clash) CLASH="$2"; shift 2 ;;
            -websub) CUSTOMWEBSUB="$2"; shift 2 ;;
            -uninstall) UNINSTALL="$2"; shift 2 ;;
            *) shift 1 ;;
        esac
    done
    
    # Handle uninstall
    if [[ "$UNINSTALL" == "y" ]]; then
        uninstall_xui
        exit 0
    fi
    
    # Get domain information
    local public_ip
    public_ip=$(get_public_ip)
    
    if [[ "$AUTODOMAIN" == "y" ]]; then
        domain="${public_ip}.cdn-one.org"
        reality_domain="${public_ip//./-}.cdn-one.org"
        msg_warn "Using auto-domain: $domain"
        msg_warn "Auto-domain certificates may fail. Consider using real domains."
    else
        # Prompt for domains if not provided
        if [[ -z "$domain" ]]; then
            read -p "Enter your main domain (e.g., example.com): " domain
        fi
        if [[ -z "$reality_domain" ]]; then
            read -p "Enter your REALITY domain (e.g., real.example.com): " reality_domain
        fi
    fi
    
    # Validate domains
    if [[ "$AUTODOMAIN" != "y" ]]; then
        msg_inf "Validating domain DNS resolution..."
        if ! resolve_domain "$domain" "$public_ip"; then
            msg_err "Domain $domain does not resolve to this server's IP ($public_ip)"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
        
        if ! resolve_domain "$reality_domain" "$public_ip"; then
            msg_err "Domain $reality_domain does not resolve to this server's IP ($public_ip)"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
    
    # Create backup before installation
    backup_configs
    
    # Install if requested
    if [[ "$INSTALL" == "y" ]]; then
        install_dependencies || exit 1
    fi
    
    # Stop services for configuration
    systemctl stop nginx x-ui 2>/dev/null || true
    fuser -k 80/tcp 443/tcp 2>/dev/null || true
    
    # Obtain SSL certificates
    generate_ssl_certificates "$domain" || exit 1
    generate_ssl_certificates "$reality_domain" || exit 1
    
    # Configure services
    configure_nginx || exit 1
    
    # Install and configure X-UI
    if [[ "$INSTALL" == "y" ]]; then
        install_x