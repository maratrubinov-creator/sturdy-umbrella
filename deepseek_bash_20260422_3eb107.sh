#!/bin/bash
#################### X-UI-PRO-SECURE v1.0.1 - Fixed Certbot Issue ##############################
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
    openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

get_public_ip() {
    local ip=""
    
    for source in "ipv4.icanhazip.com" "api.ipify.org" "ifconfig.me"; do
        ip=$(curl -s --max-time 5 "https://$source" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
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
    
    local resolved_ip
    resolved_ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    
    if [[ -z "$resolved_ip" ]]; then
        return 1
    fi
    
    [[ "$resolved_ip" == "$expected_ip" ]]
}

configure_firewall() {
    msg_inf "Configuring firewall..."
    
    if command -v ufw &>/dev/null; then
        ufw status numbered > "$CONFIG_DIR/ufw_backup.txt" 2>/dev/null || true
        ufw --force disable
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment 'SSH'
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw limit 22/tcp
        ufw --force enable
        msg_ok "UFW configured"
    elif command -v firewall-cmd &>/dev/null; then
        systemctl start firewalld 2>/dev/null || true
        systemctl enable firewalld 2>/dev/null || true
        firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
        firewall-cmd --permanent --add-service=http 2>/dev/null || true
        firewall-cmd --permanent --add-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        msg_ok "FirewallD configured"
    fi
}

optimize_system() {
    msg_inf "Optimizing system parameters..."
    
    cp /etc/sysctl.conf "$CONFIG_DIR/sysctl.conf.backup" 2>/dev/null || true
    
    # Check if settings already exist
    if ! grep -q "X-UI Performance Optimizations" /etc/sysctl.conf; then
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
EOF
        sysctl -p
    fi
    
    # Increase limits
    if ! grep -q "soft nofile 1048576" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65536
* hard nproc 65536
EOF
    fi
    
    msg_ok "System optimized"
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
    
    if command -v x-ui &>/dev/null; then
        printf 'y\n' | x-ui uninstall 2>/dev/null || true
    fi
    
    rm -rf /etc/x-ui /usr/local/x-ui /usr/bin/x-ui
    rm -rf /etc/systemd/system/x-ui.service
    
    $PKG_REMOVE nginx nginx-common nginx-core nginx-full 2>/dev/null || true
    rm -rf /etc/nginx /var/www/html
    
    msg_ok "X-UI completely removed"
    return 0
}

install_dependencies() {
    msg_inf "Installing dependencies..."
    
    $PKG_UPDATE || {
        msg_err "Failed to update package lists"
        return 1
    }
    
    # Install essential packages
    local packages="curl wget jq sudo nginx sqlite3 ufw netcat-openbsd openssl"
    
    # Add certbot and python for Ubuntu/Debian
    if [[ "$Pak" == "apt" ]]; then
        packages="$packages certbot python3-certbot-nginx fail2ban"
    else
        packages="$packages certbot fail2ban"
        # For CentOS/RHEL, add EPEL if needed
        if ! rpm -q epel-release &>/dev/null; then
            yum install -y epel-release
        fi
    fi
    
    for pkg in $packages; do
        if ! $PKG_INSTALL "$pkg" 2>/dev/null; then
            msg_warn "Failed to install $pkg, continuing..."
        fi
    done
    
    # Verify certbot is installed
    if ! command -v certbot &>/dev/null; then
        msg_warn "Certbot not found, attempting alternative installation..."
        if [[ "$Pak" == "apt" ]]; then
            apt install -y certbot python3-certbot-nginx || {
                msg_err "Failed to install certbot"
                return 1
            }
        fi
    fi
    
    # Configure fail2ban
    if command -v fail2ban-server &>/dev/null; then
        systemctl enable fail2ban 2>/dev/null || true
        systemctl start fail2ban 2>/dev/null || true
        
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
EOF
        systemctl restart fail2ban 2>/dev/null || true
    fi
    
    msg_ok "Dependencies installed"
}

install_xui_panel() {
    msg_inf "Installing X-UI panel..."
    
    local tag_version
    tag_version=$(curl -s "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | jq -r '.tag_name')
    
    if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
        msg_warn "Failed to fetch latest version, using default"
        tag_version="v2.4.3"
    fi
    
    msg_inf "Installing version: $tag_version"
    
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        *) msg_err "Unsupported architecture"; return 1 ;;
    esac
    
    local download_url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-${arch}.tar.gz"
    local temp_file="$CONFIG_DIR/x-ui.tar.gz"
    
    if ! wget -q --show-progress -O "$temp_file" "$download_url"; then
        msg_err "Failed to download X-UI"
        return 1
    fi
    
    cd /usr/local
    tar xzf "$temp_file"
    rm "$temp_file"
    
    cd x-ui
    chmod +x x-ui x-ui.sh bin/xray-linux-* 2>/dev/null || true
    
    cp -f x-ui.service /etc/systemd/system/x-ui.service 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable x-ui 2>/dev/null || true
    ln -sf /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    
    msg_ok "X-UI installed"
}

generate_ssl_certificates() {
    local domain_name=$1
    local cert_dir="/etc/letsencrypt/live/${domain_name}"
    
    # Check if certbot is available
    if ! command -v certbot &>/dev/null; then
        msg_err "Certbot is not installed. Please install it first."
        return 1
    fi
    
    # Check if certificate already exists and is valid
    if [[ -d "$cert_dir" ]]; then
        if [[ -f "$cert_dir/fullchain.pem" ]]; then
            local expiry_date
            expiry_date=$(openssl x509 -enddate -noout -in "$cert_dir/fullchain.pem" 2>/dev/null | cut -d= -f2)
            if [[ -n "$expiry_date" ]]; then
                local expiry_epoch
                expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
                local current_epoch
                current_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
                
                if [[ $days_left -gt 30 ]]; then
                    msg_ok "Valid certificate for $domain_name already exists ($days_left days left)"
                    return 0
                fi
            fi
        fi
    fi
    
    msg_inf "Obtaining SSL certificate for $domain_name..."
    
    # Stop nginx if running
    systemctl stop nginx 2>/dev/null || true
    
    # Try to get certificate
    if certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        -d "$domain_name" 2>&1 | tee -a "$LOG_FILE"; then
        msg_ok "SSL certificate obtained for $domain_name"
        return 0
    else
        msg_err "Failed to obtain SSL certificate for $domain_name"
        msg_inf "Trying with webroot method..."
        
        # Try webroot method as fallback
        mkdir -p /var/www/html/.well-known/acme-challenge
        if certbot certonly --webroot --webroot-path=/var/www/html \
            --non-interactive --agree-tos --register-unsafely-without-email \
            -d "$domain_name" 2>&1 | tee -a "$LOG_FILE"; then
            msg_ok "SSL certificate obtained for $domain_name (webroot method)"
            return 0
        fi
    fi
    
    msg_err "Failed to obtain SSL certificate for $domain_name"
    return 1
}

configure_nginx() {
    msg_inf "Configuring Nginx..."
    
    local panel_path=$(gen_random_string 10)
    local sub_path=$(gen_random_string 10)
    local json_path=$(gen_random_string 10)
    local web_path=$(gen_random_string 10)
    local sub2singbox_path=$(gen_random_string 10)
    
    local panel_port=$(get_random_port)
    local sub_port=$(get_random_port)
    local ws_port=$(get_random_port)
    local trojan_port=$(get_random_port)
    
    mkdir -p /etc/nginx/{sites-available,sites-enabled,stream-enabled}
    mkdir -p /var/www/html
    
    # Basic nginx configuration
    cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml text/js image/svg+xml;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # HTTP redirect
    cat > /etc/nginx/sites-available/redirect.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} ${reality_domain};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF
    
    # Main domain configuration
    cat > "/etc/nginx/sites-available/${domain}.conf" << EOF
server {
    server_tokens off;
    server_name ${domain};
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    
    root /var/www/html;
    index index.html;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    
    location /${panel_path}/ {
        proxy_pass http://127.0.0.1:${panel_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location /${sub_path}/ {
        proxy_pass http://127.0.0.1:${sub_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    location /${web_path} {
        root /var/www/subpage;
        index index.html;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/redirect.conf /etc/nginx/sites-enabled/
    ln -sf "/etc/nginx/sites-available/${domain}.conf" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    if ! nginx -t 2>&1; then
        msg_err "Nginx configuration is invalid"
        return 1
    fi
    
    # Save configuration
    cat > "$CONFIG_DIR/install_vars.conf" << EOF
panel_path=${panel_path}
panel_port=${panel_port}
sub_path=${sub_path}
json_path=${json_path}
sub_port=${sub_port}
ws_port=${ws_port}
web_path=${web_path}
sub2singbox_path=${sub2singbox_path}
EOF
    
    msg_ok "Nginx configured"
}

setup_web_sub_page() {
    msg_inf "Setting up web subscription page..."
    
    local web_dir="/var/www/subpage"
    mkdir -p "$web_dir"
    
    # Create simple subscription page
    cat > "$web_dir/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>VPN Subscription</title>
    <meta charset="utf-8">
</head>
<body>
    <h1>VPN Service</h1>
    <p>Subscription endpoint: /${sub_path}/</p>
    <p>JSON endpoint: /${json_path}/</p>
</body>
</html>
EOF
    
    chown -R www-data:www-data "$web_dir" 2>/dev/null || true
    chmod -R 755 "$web_dir"
    
    msg_ok "Web subscription page configured"
}

configure_cron_jobs() {
    msg_inf "Configuring scheduled tasks..."
    
    crontab -l > "$CONFIG_DIR/crontab_backup.txt" 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v "certbot\|x-ui" | crontab - || true
    
    (
        crontab -l 2>/dev/null || true
        echo "# X-UI maintenance tasks"
        echo "@daily /usr/local/x-ui/x-ui restart > /dev/null 2>&1"
        echo "@weekly certbot renew --quiet --nginx --post-hook 'systemctl reload nginx'"
    ) | crontab -
    
    msg_ok "Cron jobs configured"
}

configure_xui_settings() {
    msg_inf "Configuring X-UI settings..."
    
    local config_username=$(gen_random_string 10)
    local config_password=$(gen_random_string 10)
    
    if [[ -f "$CONFIG_DIR/install_vars.conf" ]]; then
        source "$CONFIG_DIR/install_vars.conf"
        
        if [[ -f /usr/local/x-ui/x-ui ]]; then
            /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}" 2>/dev/null || true
            
            cat >> "$CONFIG_DIR/install_vars.conf" << EOF
config_username=${config_username}
config_password=${config_password}
EOF
        fi
    fi
    
    msg_ok "X-UI configured"
}

display_summary() {
    if [[ -f "$CONFIG_DIR/install_vars.conf" ]]; then
        source "$CONFIG_DIR/install_vars.conf"
    fi
    
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
    echo
    echo -e "${BLUE}🛡️ Security Status:${NC}"
    echo -e "   ✓ Firewall: Configured"
    echo -e "   ✓ SSL/TLS: Let's Encrypt"
    echo -e "   ✓ System Hardening: Applied"
    echo
    echo -e "${BLUE}📁 Important Files:${NC}"
    echo -e "   Backup Directory: ${YELLOW}${BACKUP_DIR:-Not created}${NC}"
    echo -e "   Log File: ${YELLOW}$LOG_FILE${NC}"
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️  IMPORTANT: Save this information!${NC}"
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
        if [[ -z "$domain" ]]; then
            read -p "Enter your main domain (e.g., example.com): " domain
        fi
        if [[ -z "$reality_domain" ]]; then
            reality_domain="$domain"
            msg_inf "Using same domain for REALITY: $reality_domain"
        fi
    fi
    
    # Step 1: Create backup
    backup_configs
    
    # Step 2: Install dependencies FIRST
    if [[ "$INSTALL" == "y" ]]; then
        install_dependencies || exit 1
    fi
    
    # Step 3: Configure firewall and system
    configure_firewall
    optimize_system
    
    # Step 4: Stop services for SSL generation
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 443/tcp 2>/dev/null || true
    
    # Step 5: Generate SSL certificates
    generate_ssl_certificates "$domain" || {
        msg_err "Failed to generate SSL certificate for $domain"
        msg_inf "You can try to obtain certificate manually:"
        echo "  certbot certonly --standalone -d $domain"
        exit 1
    }
    
    # Step 6: Configure nginx
    configure_nginx || exit 1
    
    # Step 7: Install X-UI
    if [[ "$INSTALL" == "y" ]]; then
        install_xui_panel || exit 1
    fi
    
    # Step 8: Configure X-UI
    configure_xui_settings
    
    # Step 9: Setup web interface
    setup_web_sub_page
    
    # Step 10: Configure cron jobs
    configure_cron_jobs
    
    # Step 11: Start services
    systemctl start nginx
    systemctl start x-ui 2>/dev/null || true
    
    sleep 3
    
    # Final check
    if systemctl is-active --quiet nginx; then
        display_summary
    else
        msg_err "Nginx failed to start"
        journalctl -u nginx -n 20 --no-pager
        exit 1
    fi
}

main "$@"