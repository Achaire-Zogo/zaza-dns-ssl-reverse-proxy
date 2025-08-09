#!/bin/bash

set -e

SSL_BASE_DIR="/etc/ssl/local_certs"
BIND_CONF="/etc/bind/named.conf.local"
BIND_ZONE_DIR="/etc/bind"
BIND_SERVICE="bind9"
APACHE_SERVICE="apache2"
NGINX_SERVICE="nginx"

function check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "⚠️  Ce script doit être exécuté en root (sudo)."
    exit 1
  fi
}

function install_packages() {
  echo "📦 Installation des paquets requis..."
  apt update
  apt install -y bind9 bind9utils bind9-doc openssl
  if [[ "$1" == "apache2" ]]; then
    apt install -y apache2
  elif [[ "$1" == "nginx" ]]; then
    apt install -y nginx
  fi
}

function create_bind_zone() {
  local domain=$1
  local ip=$2
  local zone_file="$BIND_ZONE_DIR/db.$domain"

  # Ajouter la zone dans named.conf.local si non présente
  if ! grep -q "$domain" "$BIND_CONF"; then
    echo -e "\nzone \"$domain\" {\n\ttype master;\n\tfile \"$zone_file\";\n};" >> "$BIND_CONF"
  fi

  # Créer le fichier de zone
  cat > "$zone_file" <<EOF
\$TTL    604800
@       IN      SOA     ns1.$domain. admin.$domain. (
                        $(date +%Y%m%d01) ; Serial
                        604800     ; Refresh
                        86400      ; Retry
                        2419200    ; Expire
                        604800 )   ; Negative Cache TTL

; NS records
@       IN      NS      ns1.$domain.
ns1     IN      A       $ip

; A records
@       IN      A       $ip
*       IN      A       $ip
EOF

  echo "✅ Zone Bind9 $domain créée pointant vers $ip"
}

function reload_bind() {
  named-checkconf
  named-checkzone "$domain" "$BIND_ZONE_DIR/db.$domain"
  systemctl restart "$BIND_SERVICE"
  systemctl enable "$BIND_SERVICE"
  echo "✅ Bind9 rechargé"
}

function generate_wildcard_cert() {
  local domain=$1
  local ssl_dir="$SSL_BASE_DIR/$domain"
  mkdir -p "$ssl_dir"

  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$ssl_dir/$domain.key" \
    -out "$ssl_dir/$domain.crt" \
    -subj "/C=FR/ST=Local/L=Local/O=LocalDev/OU=IT/CN=*.$domain"

  cp "$ssl_dir/$domain.crt" "/usr/local/share/ca-certificates/$domain.crt"
  update-ca-certificates
  echo "✅ Certificat wildcard auto-signé généré et ajouté aux autorités de confiance"
}

function configure_apache() {
  local domain=$1
  local port=$2
  local ssl_dir="$SSL_BASE_DIR/$domain"
  a2enmod ssl proxy proxy_http || true

  local conf_path="/etc/apache2/sites-available/$domain.conf"
  cat > "$conf_path" <<EOF
<VirtualHost *:80>
  ServerName $domain
  ServerAlias *.$domain
  Redirect permanent / https://$domain/
</VirtualHost>

<VirtualHost *:443>
  ServerName $domain
  ServerAlias *.$domain
  SSLEngine on
  SSLCertificateFile $ssl_dir/$domain.crt
  SSLCertificateKeyFile $ssl_dir/$domain.key

  ProxyPreserveHost On
  ProxyPass / http://127.0.0.1:$port/
  ProxyPassReverse / http://127.0.0.1:$port/
</VirtualHost>
EOF

  a2ensite "$domain.conf"
  systemctl reload "$APACHE_SERVICE"
  echo "✅ Apache2 configuré avec HTTPS wildcard pour $domain → 127.0.0.1:$port"
}

function configure_nginx() {
  local domain=$1
  local port=$2
  local ssl_dir="$SSL_BASE_DIR/$domain"

  local conf_path="/etc/nginx/sites-available/$domain"
  cat > "$conf_path" <<EOF
server {
  listen 80;
  server_name $domain *.$domain;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl;
  server_name $domain *.$domain;

  ssl_certificate $ssl_dir/$domain.crt;
  ssl_certificate_key $ssl_dir/$domain.key;

  location / {
    proxy_pass http://127.0.0.1:$port;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  ln -sf "$conf_path" /etc/nginx/sites-enabled/
  nginx -t && systemctl reload "$NGINX_SERVICE"
  echo "✅ Nginx configuré avec HTTPS wildcard pour $domain → 127.0.0.1:$port"
}

function remove_bind_zone() {
  local domain=$1
  local zone_file="$BIND_ZONE_DIR/db.$domain"

  # Supprimer la zone du conf Bind9
  sed -i "/zone \"$domain\" {/,/};/d" "$BIND_CONF"

  # Supprimer le fichier de zone
  rm -f "$zone_file"

  systemctl restart "$BIND_SERVICE"
  echo "🗑 Zone Bind9 $domain supprimée"
}

function remove_apache_conf() {
  local domain=$1
  local conf_path="/etc/apache2/sites-available/$domain.conf"
  a2dissite "$domain.conf" || true
  rm -f "$conf_path"
  systemctl reload "$APACHE_SERVICE"
  echo "🗑 Config Apache2 $domain supprimée"
}

function remove_nginx_conf() {
  local domain=$1
  local conf_path="/etc/nginx/sites-available/$domain"
  rm -f "$conf_path"
  rm -f "/etc/nginx/sites-enabled/$domain"
  nginx -t && systemctl reload "$NGINX_SERVICE"
  echo "🗑 Config Nginx $domain supprimée"
}

function remove_certificates() {
  local domain=$1
  local ssl_dir="$SSL_BASE_DIR/$domain"
  rm -rf "$ssl_dir"
  rm -f "/usr/local/share/ca-certificates/$domain.crt"
  update-ca-certificates --fresh
  echo "🗑 Certificats $domain supprimés"
}

function usage() {
  echo "Usage: $0"
  echo "Choisissez :"
  echo "  a : Ajouter une configuration"
  echo "  s : Supprimer une configuration"
}

check_root

echo "=== Gestion DNS local + SSL wildcard + Reverse Proxy ==="
read -p "Voulez-vous (a)jouter ou (s)upprimer une configuration ? [a/s] : " ACTION

if [[ "$ACTION" == "a" ]]; then
  read -p "Nom de domaine interne (ex: monprojet.local) : " domain
  read -p "Adresse IP cible (ex: 192.168.0.50) pour Bind9 : " target_ip
  read -p "Serveur web à configurer (apache2/nginx) : " server
  read -p "Port local de redirection (ex: 8080) pour reverse proxy : " port

  install_packages "$server"
  create_bind_zone "$domain" "$target_ip"
  reload_bind
  generate_wildcard_cert "$domain"

  if [[ "$server" == "apache2" ]]; then
    configure_apache "$domain" "$port"
  elif [[ "$server" == "nginx" ]]; then
    configure_nginx "$domain" "$port"
  else
    echo "⚠️ Serveur web inconnu : $server"
    exit 1
  fi

  echo "🎯 Configuration terminée. Pense à mettre l’IP Bind9 ($HOSTNAME) comme DNS primaire dans le DHCP."

elif [[ "$ACTION" == "s" ]]; then
  read -p "Nom de domaine à supprimer : " domain
  read -p "Serveur web utilisé (apache2/nginx) : " server

  remove_bind_zone "$domain"
  remove_certificates "$domain"

  if [[ "$server" == "apache2" ]]; then
    remove_apache_conf "$domain"
  elif [[ "$server" == "nginx" ]]; then
    remove_nginx_conf "$domain"
  else
    echo "⚠️ Serveur web inconnu : $server"
    exit 1
  fi

  echo "🎯 Suppression terminée."

else
  usage
  exit 1
fi
