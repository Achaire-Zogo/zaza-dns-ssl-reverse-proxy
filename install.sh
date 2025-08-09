#!/bin/bash

# Couleurs pour les messages
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Fonction pour afficher les étapes
show_step() {
    echo -e "${BLUE}[ÉTAPE]${NC} $1"
}

# Fonction pour afficher les succès
show_success() {
    echo -e "${GREEN}[SUCCÈS]${NC} $1"
}

# Fonction pour afficher les erreurs
show_error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

# Fonction pour afficher les avertissements
show_warning() {
    echo -e "${YELLOW}[AVERTISSEMENT]${NC} $1"
}

# Fonction pour créer des sauvegardes de fichiers
backup_file() {
    if [ -f "$1" ]; then
        local backup_file="$1.bak.$(date +%Y%m%d%H%M%S)"
        cp "$1" "$backup_file"
        show_step "Sauvegarde créée: $backup_file"
    fi
}

# Fonction pour valider une adresse IP
validate_ip() {
    local ip=$1
    local stat=1
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Fonction pour valider un nom de domaine
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Fonction pour valider un numéro de port
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    
    # Vérifier si le port est déjà utilisé
    if netstat -tuln | grep -q ":$port "; then
        show_warning "Le port $port semble déjà être utilisé par un autre service."
        read -p "Voulez-vous continuer quand même? (y/n): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Fonction pour nettoyer en cas d'erreur
cleanup() {
    show_error "Une erreur est survenue. Nettoyage en cours..."
    # Restaurer les fichiers de sauvegarde si nécessaire
    if [ -n "$VHOST_FILE" ] && [ -f "${VHOST_FILE}.bak" ]; then
        mv "${VHOST_FILE}.bak" "$VHOST_FILE"
    fi
    exit 1
}

# Configurer le gestionnaire d'erreurs
trap cleanup ERR

# Vérifier si le script est exécuté en tant que root
if [ "$EUID" -ne 0 ]; then 
    show_error "Ce script doit être exécuté en tant que root (sudo)"
    exit 1
fi

# Vérifier si BIND9 est installé
show_step "Vérification de BIND9..."
if ! command -v named &> /dev/null; then
    show_step "Installation de BIND9..."
    if ! apt-get update; then
        show_error "Échec de la mise à jour des paquets. Vérifiez votre connexion Internet."
        exit 1
    fi
    
    if ! apt-get install -y bind9 bind9utils; then
        show_error "Échec de l'installation de BIND9. Vérifiez les journaux système."
        exit 1
    fi
    
    # Déterminer le bon nom de service pour BIND9 (named ou bind9)
    BIND_SERVICE="bind9"
    if systemctl list-unit-files | grep -q "named.service"; then
        BIND_SERVICE="named"
    fi
    
    if ! systemctl start $BIND_SERVICE; then
        show_error "Échec du démarrage de BIND9 ($BIND_SERVICE). Vérifiez les journaux système avec 'journalctl -xe'."
        exit 1
    fi
    
    systemctl enable $BIND_SERVICE
    show_success "BIND9 installé et démarré"
else
    # Déterminer le bon nom de service pour BIND9 (named ou bind9)
    BIND_SERVICE="bind9"
    if systemctl list-unit-files | grep -q "named.service"; then
        BIND_SERVICE="named"
    fi
    
    # Vérifier si BIND9 est en cours d'exécution
    if ! systemctl is-active --quiet $BIND_SERVICE; then
        show_warning "BIND9 est installé mais n'est pas en cours d'exécution."
        read -p "Voulez-vous démarrer BIND9 maintenant? (y/n): " start_bind
        if [[ "$start_bind" =~ ^[Yy]$ ]]; then
            systemctl start $BIND_SERVICE
            systemctl enable $BIND_SERVICE
            show_success "BIND9 démarré et activé"
        else
            show_warning "BIND9 n'a pas été démarré. Le script continuera, mais la résolution DNS ne fonctionnera pas."
        fi
    else
        show_success "BIND9 est déjà installé et en cours d'exécution"
    fi
fi

# Demander et valider les informations nécessaires
while true; do
    read -p "Entrez le nom de domaine (ex: monapp.local) : " DOMAIN_NAME
    if validate_domain "$DOMAIN_NAME"; then
        break
    else
        show_error "Nom de domaine invalide. Veuillez réessayer."
    fi
done

while true; do
    read -p "Entrez l'adresse IP du serveur : " IP_ADDRESS
    if validate_ip "$IP_ADDRESS"; then
        break
    else
        show_error "Adresse IP invalide. Veuillez entrer une adresse IPv4 valide."
    fi
done

while true; do
    read -p "Entrez le port pour l'application Laravel (1024-65535 recommandé) : " PORT_NUMBER
    if validate_port "$PORT_NUMBER"; then
        break
    else
        show_error "Port invalide. Veuillez entrer un numéro de port valide (1-65535)."
    fi
done

read -p "Voulez-vous configurer HTTPS pour ce domaine? (y/n) : " ENABLE_SSL

# Vérifier si le port est déjà configuré dans Apache
show_step "Vérification de la configuration Apache..."
if [ ! -f /etc/apache2/ports.conf ]; then
    show_error "Le fichier /etc/apache2/ports.conf n'existe pas. Apache est-il correctement installé?"
    exit 1
fi

# Sauvegarder le fichier ports.conf avant modification
backup_file "/etc/apache2/ports.conf"

if ! grep -q "Listen $PORT_NUMBER" /etc/apache2/ports.conf; then
    echo "Listen $PORT_NUMBER" >> /etc/apache2/ports.conf
    show_success "Port $PORT_NUMBER ajouté à Apache"
fi

# Si SSL est activé, vérifier si le port 443 est configuré
if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    if ! grep -q "Listen 443" /etc/apache2/ports.conf; then
        echo "Listen 443" >> /etc/apache2/ports.conf
        show_success "Port 443 ajouté à Apache pour HTTPS"
    fi
fi

# Créer la zone DNS
show_step "Configuration de la zone DNS..."
DNS_FILE="/etc/bind/db.$DOMAIN_NAME"

# Sauvegarder le fichier de zone s'il existe déjà
backup_file "$DNS_FILE"

cat > "$DNS_FILE" << EOF
\$TTL    604800
@       IN      SOA     $DOMAIN_NAME. root.$DOMAIN_NAME. (
                     $(date +%Y%m%d)01     ; Serial
                         604800     ; Refresh
                          86400     ; Retry
                        2419200     ; Expire
                         604800 )   ; Negative Cache TTL
;
@       IN      NS      ns1.$DOMAIN_NAME.
@       IN      A       $IP_ADDRESS
ns1     IN      A       $IP_ADDRESS
www     IN      A       $IP_ADDRESS
EOF

# Configurer la zone dans named.conf.local
show_step "Ajout de la zone dans named.conf.local..."
NAMED_CONF="/etc/bind/named.conf.local"

# Sauvegarder named.conf.local avant modification
backup_file "$NAMED_CONF"

# Vérifier si la zone existe déjà
if grep -q "zone \"$DOMAIN_NAME\"" "$NAMED_CONF"; then
    show_warning "La zone pour $DOMAIN_NAME existe déjà dans named.conf.local."
    read -p "Voulez-vous remplacer la configuration existante? (y/n): " replace_zone
    if [[ "$replace_zone" =~ ^[Yy]$ ]]; then
        # Supprimer l'ancienne configuration de zone
        sed -i "/zone \"$DOMAIN_NAME\"/,/};/d" "$NAMED_CONF"
    else
        show_warning "Conservation de la configuration de zone existante."
    fi
fi

# Ajouter la nouvelle configuration de zone si nécessaire
if ! grep -q "zone \"$DOMAIN_NAME\"" "$NAMED_CONF"; then
    cat >> "$NAMED_CONF" << EOF
zone "$DOMAIN_NAME" {
    type master;
    file "/etc/bind/db.$DOMAIN_NAME";
};
EOF
    show_success "Zone DNS ajoutée à named.conf.local"
fi

# Créer le VirtualHost Apache
show_step "Création du VirtualHost Apache..."
VHOST_FILE="/etc/apache2/sites-available/$DOMAIN_NAME.conf"

# Sauvegarder le fichier VirtualHost s'il existe déjà
backup_file "$VHOST_FILE"

# Vérifier si le dossier de destination existe
APP_DIR="/var/www/html/$DOMAIN_NAME"
if [ ! -d "$APP_DIR" ]; then
    show_warning "Le répertoire $APP_DIR n'existe pas."
    read -p "Voulez-vous le créer maintenant? (y/n): " create_dir
    if [[ "$create_dir" =~ ^[Yy]$ ]]; then
        mkdir -p "$APP_DIR/public"
        chown -R www-data:www-data "$APP_DIR"
        show_success "Répertoire $APP_DIR créé"
    else
        show_warning "Le répertoire n'a pas été créé. Assurez-vous de le créer manuellement avant d'utiliser le domaine."
    fi
fi

# Configurer les permissions pour Laravel si le répertoire existe
if [ -d "$APP_DIR" ]; then
    show_step "Configuration des permissions pour Laravel..."
    # Vérifier si les répertoires critiques existent
    if [ -d "$APP_DIR/storage" ]; then
        chmod -R 775 "$APP_DIR/storage"
        show_success "Permissions configurées pour le répertoire storage"
    fi
    
    if [ -d "$APP_DIR/bootstrap/cache" ]; then
        chmod -R 775 "$APP_DIR/bootstrap/cache"
        show_success "Permissions configurées pour le répertoire bootstrap/cache"
    fi
    
    # Définir le groupe www-data pour permettre l'accès au serveur web
    chown -R :www-data "$APP_DIR/storage" 2>/dev/null || show_warning "Impossible de changer le groupe du répertoire storage"
    chown -R :www-data "$APP_DIR/bootstrap/cache" 2>/dev/null || show_warning "Impossible de changer le groupe du répertoire bootstrap/cache"
fi

if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    # Installation de certbot si nécessaire
    show_step "Vérification de certbot..."
    if ! command -v certbot &> /dev/null; then
        show_step "Installation de certbot..."
        if ! apt-get update || ! apt-get install -y certbot python3-certbot-apache; then
            show_error "Échec de l'installation de certbot. Le VirtualHost sera configuré sans SSL."
            ENABLE_SSL="n"
        fi
    fi

    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        # Créer d'abord le VirtualHost HTTP pour la validation de certbot
        cat > "$VHOST_FILE" << EOF
<VirtualHost *:$PORT_NUMBER>
    ServerName $DOMAIN_NAME
    ServerAlias www.$DOMAIN_NAME
    DocumentRoot /var/www/html/$DOMAIN_NAME/public

    <Directory /var/www/html/$DOMAIN_NAME>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN_NAME-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN_NAME-access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN_NAME
    ServerAlias www.$DOMAIN_NAME
    DocumentRoot /var/www/html/$DOMAIN_NAME/public

    <Directory /var/www/html/$DOMAIN_NAME>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN_NAME-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN_NAME-ssl-access.log combined

    # Les certificats seront configurés par certbot
</VirtualHost>
EOF
    fi
else
    # Configuration standard sans SSL
    cat > "$VHOST_FILE" << EOF
<VirtualHost *:$PORT_NUMBER>
    ServerName $DOMAIN_NAME
    ServerAlias www.$DOMAIN_NAME
    DocumentRoot /var/www/html/$DOMAIN_NAME/public

    <Directory /var/www/html/$DOMAIN_NAME>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN_NAME-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN_NAME-access.log combined
</VirtualHost>
EOF
fi

# Désactiver le site par défaut d'Apache2
show_step "Désactivation du site par défaut d'Apache2..."
if [ -f /etc/apache2/sites-enabled/000-default.conf ]; then
    if ! a2dissite 000-default.conf; then
        show_warning "Impossible de désactiver le site par défaut d'Apache2. Il pourrait y avoir des conflits."
    else
        show_success "Site par défaut d'Apache2 désactivé"
    fi
fi

# Activer le site
show_step "Activation du VirtualHost..."
if ! a2ensite "$DOMAIN_NAME.conf"; then
    show_error "Échec de l'activation du VirtualHost. Vérifiez la syntaxe du fichier de configuration."
    exit 1
fi

# Activer les modules Apache nécessaires
show_step "Activation des modules Apache nécessaires..."
a2enmod rewrite
show_success "Module rewrite activé"

# Activer les modules proxy si nécessaire
if [[ "$DIFFERENT_PORT" =~ ^[Yy]$ ]] && [ "$APP_PORT" != "$PORT_NUMBER" ]; then
    show_step "Activation des modules proxy..."
    a2enmod proxy
    a2enmod proxy_http
    show_success "Modules proxy activés"
fi

if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    show_step "Activation des modules SSL..."
    a2enmod ssl
    show_success "Module SSL activé"
fi

# Vérifier la configuration
show_step "Vérification de la configuration BIND9..."
if ! named-checkconf; then
    show_error "La configuration de BIND9 contient des erreurs. Vérifiez les journaux pour plus de détails."
    exit 1
fi

if ! named-checkzone "$DOMAIN_NAME" "/etc/bind/db.$DOMAIN_NAME"; then
    show_error "La zone DNS pour $DOMAIN_NAME contient des erreurs. Vérifiez le fichier /etc/bind/db.$DOMAIN_NAME."
    exit 1
fi

# # Vérifier et ajouter l'entrée dans le fichier hosts si nécessaire
# show_step "Vérification du fichier /etc/hosts..."
# if ! grep -q "$IP_ADDRESS[[:space:]]\+$DOMAIN_NAME" /etc/hosts; then
#     show_step "Ajout de l'entrée dans le fichier /etc/hosts..."
#     # Sauvegarder le fichier hosts avant modification
#     backup_file "/etc/hosts"
    
#     # Ajouter l'entrée dans le fichier hosts
#     echo "$IP_ADDRESS\t$DOMAIN_NAME www.$DOMAIN_NAME" >> /etc/hosts
#     show_success "Entrée ajoutée dans le fichier /etc/hosts"
# else
#     show_success "L'entrée existe déjà dans le fichier /etc/hosts"
# fi

# Redémarrer les services
show_step "Redémarrage des services..."

# Déterminer le bon nom de service pour BIND9 (named ou bind9)
BIND_SERVICE="bind9"
if systemctl list-unit-files | grep -q "named.service"; then
    BIND_SERVICE="named"
fi

show_step "Redémarrage du service $BIND_SERVICE..."
if ! systemctl restart $BIND_SERVICE; then
    show_error "Échec du redémarrage de BIND9 ($BIND_SERVICE). Vérifiez les journaux avec 'journalctl -xe'."
    exit 1
fi

if ! systemctl restart apache2; then
    show_error "Échec du redémarrage d'Apache. Vérifiez les journaux avec 'journalctl -xe'."
    exit 1
fi

# Configuration SSL avec certbot si demandé
if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    show_step "Configuration des certificats SSL avec Let's Encrypt..."
    if ! certbot --apache -d "$DOMAIN_NAME" -d "www.$DOMAIN_NAME" --non-interactive --agree-tos --email "webmaster@$DOMAIN_NAME"; then
        show_warning "Échec de l'obtention des certificats SSL. Vous pourrez réessayer plus tard avec: certbot --apache -d $DOMAIN_NAME -d www.$DOMAIN_NAME"
    else
        show_success "Certificats SSL installés avec succès"
    fi
fi

show_success "Configuration terminée!"
echo -e "${GREEN}Pour tester, vous pouvez utiliser:${NC}"
echo "nslookup $DOMAIN_NAME"
if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    echo "curl https://$DOMAIN_NAME"
    echo "curl http://$DOMAIN_NAME:$PORT_NUMBER (redirection vers HTTPS)"
else
    echo "curl http://$DOMAIN_NAME:$PORT_NUMBER"
fi

echo -e "\n${GREEN}Notes importantes:${NC}"
echo "1. Assurez-vous que votre application Laravel est installée dans: /var/www/html/$DOMAIN_NAME"
echo "2. Le dossier public de Laravel doit être accessible et avoir les bonnes permissions"
echo "3. N'oubliez pas de configurer le fichier .env de Laravel avec le bon nom de domaine"
echo "4. Configurez votre base de données dans le fichier .env de Laravel:"
echo "   DB_CONNECTION=mysql"
echo "   DB_HOST=127.0.0.1"
echo "   DB_PORT=3306"
echo "   DB_DATABASE=nom_de_votre_base"
echo "   DB_USERNAME=utilisateur"
echo "   DB_PASSWORD=mot_de_passe"
echo "5. Exécutez les migrations Laravel avec: cd $APP_DIR && php artisan migrate"
if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    echo "6. Les certificats SSL seront automatiquement renouvelés par certbot"
    echo "7. Vérifiez que le port 443 est ouvert sur votre pare-feu"
fi

# Afficher le résumé de la configuration
echo -e "\n${GREEN}Résumé de la configuration:${NC}"
echo "Nom de domaine: $DOMAIN_NAME"
echo "Adresse IP: $IP_ADDRESS"
echo "Port: $PORT_NUMBER"
echo "SSL activé: ${ENABLE_SSL}"
echo "Fichier de zone DNS: /etc/bind/db.$DOMAIN_NAME"
echo "Fichier VirtualHost: $VHOST_FILE"
echo "Répertoire de l'application: $APP_DIR"

# Créer un fichier de log de l'installation
LOG_FILE="/var/log/zaz-dns-install-$DOMAIN_NAME.log"
{
    echo "Installation effectuée le $(date)"
    echo "Nom de domaine: $DOMAIN_NAME"
    echo "Adresse IP: $IP_ADDRESS"
    echo "Port: $PORT_NUMBER"
    echo "SSL activé: ${ENABLE_SSL}"
    echo "Fichier de zone DNS: /etc/bind/db.$DOMAIN_NAME"
    echo "Fichier VirtualHost: $VHOST_FILE"
    echo "Répertoire de l'application: $APP_DIR"
} > "$LOG_FILE"

show_success "Un journal d'installation a été créé dans $LOG_FILE"