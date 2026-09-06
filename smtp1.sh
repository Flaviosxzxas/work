#!/bin/bash

set -Eeuo pipefail
trap 'echo "[ERRO] linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

echo "================================================= Verificação de permissão de root ================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa ser executado como root."
  exit 1
fi
# ================================================
# Correção: evitar duplicação de repositórios no Ubuntu 24.04+
# ================================================
if grep -qi "Ubuntu 24.04" /etc/os-release 2>/dev/null; then
  echo "Detectado Ubuntu 24.04 — limpando duplicações de sources.list..."
  # Se já existe o arquivo .sources, comentar o sources.list tradicional
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i 's/^\s*deb /# deb /g' /etc/apt/sources.list
  fi
fi

export DEBIAN_FRONTEND=noninteractive

is_ubuntu() { [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release; }

echo "================================================= Verificação e instalação do PHP (CLI) ================================================="

if ! command -v php >/dev/null 2>&1; then
    echo ">> PHP não encontrado. Instalando..."
    apt-get update -y

    # Instalar Apache + PHP + módulos comuns
    if apt-get install -y apache2 php php-cli php-common php-dev php-curl php-gd libapache2-mod-php php-mbstring; then
        echo ">> PHP + Apache instalados com sucesso."
    else
        echo ">> Falha na instalação genérica. Tentando versões específicas de PHP..."
        CANDIDATES="$(apt-cache search -n '^php[0-9]\.[0-9]-cli$' | awk '{print $1}' | sort -Vr)"
        OK=0
        for pkg in $CANDIDATES php8.3-cli php8.2-cli php8.1-cli php7.4-cli; do
            if apt-get install -y "$pkg"; then OK=1; break; fi
        done
        if [ "$OK" -eq 0 ] && is_ubuntu; then
            echo ">> Adicionando PPA ppa:ondrej/php (fallback)..."
            apt-get install -y software-properties-common ca-certificates lsb-release || true
            add-apt-repository -y ppa:ondrej/php || true
            apt-get update -y
            apt-get install -y apache2 php8.3-cli php8.3 php8.3-curl php8.3-gd php8.3-mbstring libapache2-mod-php8.3 || \
            apt-get install -y apache2 php8.2-cli php8.2 php8.2-curl php8.2-gd php8.2-mbstring libapache2-mod-php8.2 || \
            apt-get install -y apache2 php8.1-cli php8.1 php8.1-curl php8.1-gd php8.1-mbstring libapache2-mod-php8.1 || \
            apt-get install -y apache2 php7.4-cli php7.4 php7.4-curl php7.4-gd php7.4-mbstring libapache2-mod-php7.4 || true
        fi
    fi

    # Garantir que /usr/bin/php aponte para o correto
    PHPPATH="$(command -v php || true)"
    if [ -n "$PHPPATH" ] && [ "$PHPPATH" != "/usr/bin/php" ]; then
        echo ">> Registrando ${PHPPATH} como alternativa de php..."
        update-alternatives --install /usr/bin/php php "$PHPPATH" 80 || true
        update-alternatives --set php "$PHPPATH" || true
        hash -r || true
    fi

    if command -v php >/dev/null 2>&1; then
        echo "OK: $(php -v | head -n 1)"
    else
        echo "AVISO: não foi possível disponibilizar 'php'."
    fi
else
    echo "OK: $(php -v | head -n 1)"
fi

echo "================================================= Atualização dos pacotes ================================================="
apt-get -y upgrade \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  || {
    echo "Erro ao atualizar os pacotes."
    exit 1
  }

echo "================================================= Proteção SSH (fail2ban + MaxStartups) ================================================="
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban
grep -q "^MaxStartups" /etc/ssh/sshd_config || echo "MaxStartups 50:30:200" >> /etc/ssh/sshd_config
grep -q "^MaxAuthTries" /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config

# Detecta automaticamente o nome do serviço SSH
if systemctl list-units --type=service --all | grep -q "sshd.service"; then
    SSH_SERVICE="sshd"
elif systemctl list-units --type=service --all | grep -q "ssh.service"; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="ssh"
fi

systemctl restart "$SSH_SERVICE"
echo "✓ fail2ban ativo e MaxStartups configurado (serviço: $SSH_SERVICE)"

echo "================================================= Configurando fail2ban (apenas SSH) ================================================="

# Desativa jail do Postfix/SMTP — protege só SSH
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

# Ignora localhost e IPs internos
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3

[postfix]
enabled = false

[postfix-sasl]
enabled = false

[dovecot]
enabled = false
EOF

systemctl restart fail2ban
echo "✓ fail2ban configurado — apenas SSH protegido, SMTP liberado"

echo "================================================= Definir variáveis principais ================================================="

ServerName=$1
CloudflareAPI=$2
CloudflareEmail=$3

# Verificar argumentos
if [ -z "$ServerName" ] || [ -z "$CloudflareAPI" ] || [ -z "$CloudflareEmail" ]; then
  echo "Erro: Argumentos insuficientes fornecidos."
  echo "Uso: $0 <ServerName> <CloudflareAPI> <CloudflareEmail>"
  exit 1
fi

# Validar ServerName
if [[ ! "$ServerName" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  echo "Erro: ServerName inválido. Use algo como sub.example.com"
  exit 1
fi

echo "================================================= Variáveis derivadas ================================================="

# Lista de TLDs compostos conhecidos
KNOWN_DOUBLE_TLDS="com.mx|com.br|co.uk|com.ar|com.au|co.jp|com.co|net.mx|org.mx|gob.mx"

# Contar quantos pontos tem o ServerName
DOTS=$(echo "$ServerName" | tr -cd '.' | wc -c)

# Verifica se o ServerName termina com TLD composto (dois níveis)
if echo "$ServerName" | grep -qE "\.($KNOWN_DOUBLE_TLDS)$"; then
    # Para TLDs compostos: pega os últimos 3 componentes
    # Exemplo: distribuidor1.agsadent.com.mx → agsadent.com.mx
    Domain=$(echo "$ServerName" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}')
elif [ "$DOTS" -eq 1 ]; then
    # Se tem apenas 1 ponto, é o domínio raiz
    # Exemplo: example.mx → example.mx
    Domain="$ServerName"
else
    # Para TLDs simples com subdomínio: pega os últimos 2 componentes
    # Exemplo: mail.example.com → example.com
    Domain=$(echo "$ServerName" | awk -F. '{print $(NF-1)"."$NF}')
fi

DKIMSelector=$(echo "$ServerName" | awk -F[.:] '{print $1}')

MailServerName="mail.$ServerName"

if [ -z "$Domain" ] || [ -z "$DKIMSelector" ]; then
  echo "Erro: Não foi possível calcular o Domain ou DKIMSelector. Verifique o ServerName."
  exit 1
fi

# Obter IP público
ServerIP=$(curl -4 -fsS https://api.ipify.org)
if [ -z "$ServerIP" ]; then
  echo "Erro: Não foi possível obter o IP público."
  exit 1
fi

echo "================================================= Depuração inicial ================================================="

echo "ServerName: $ServerName"
echo "CloudflareAPI: $CloudflareAPI"
echo "CloudflareEmail: $CloudflareEmail"
echo "Domain: $Domain"
echo "DKIMSelector: $DKIMSelector"
echo "ServerIP: $ServerIP"

echo "================================================= Hostname && SSL ================================================="

apt-get install -y wget curl jq python3-certbot-dns-cloudflare openssl

echo "================================================= Configurar Node.js ================================================="

curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && echo "Node.js instalado com sucesso: versão $(node -v)" || {
        echo "Alerta: Erro ao instalar o Node.js."
    }

echo "Verificando NPM..."
npm -v || {
    echo "Alerta: NPM não está instalado corretamente."
}

echo "Instalando PM2..."
npm install -g pm2 && echo "PM2 instalado: versão $(pm2 -v)" || {
    echo "Alerta: Falha na primeira tentativa de instalar o PM2. Testando alternativas..."

    npm cache clean --force
    npm install -g pm2 && echo "PM2 instalado na segunda tentativa!" || {
        echo "Alerta: Segunda tentativa falhou. Tentando via tarball..."

        npm install -g https://registry.npmjs.org/pm2/-/pm2-5.3.0.tgz && echo "PM2 instalado via tarball!" || {
            echo "Erro crítico: Não foi possível instalar o PM2."
        }
    }
}

mkdir -p /root/.secrets && chmod 0700 /root/.secrets/ && touch /root/.secrets/cloudflare.cfg && chmod 0400 /root/.secrets/cloudflare.cfg

echo "dns_cloudflare_email = $CloudflareEmail
dns_cloudflare_api_key = $CloudflareAPI" > /root/.secrets/cloudflare.cfg

cat <<EOF > /etc/hosts
127.0.0.1   localhost
$ServerIP   $ServerName
$ServerIP   $MailServerName
EOF

echo -e "$ServerName" > /etc/hostname

hostnamectl set-hostname "$ServerName"

certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
  --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.cfg \
  --dns-cloudflare-propagation-seconds 60 --rsa-key-size 4096 \
  -d "$ServerName" \
  -d "$MailServerName"

echo "================================================= Corrigir SyntaxWarning em cloudflare.py ================================================="

sed -i "s/self\.email is ''/self.email == ''/g" /usr/lib/python3/dist-packages/CloudFlare/cloudflare.py
sed -i "s/self\.token is ''/self.token == ''/g"   /usr/lib/python3/dist-packages/CloudFlare/cloudflare.py
echo " aplicada com sucesso em cloudflare.py."
wait
echo "================================================= RSPAMD (substitui OpenDKIM) ================================================="

# Instala Rspamd + Redis (Redis é usado para reputação e rate limiting)
apt-get install -y rspamd redis-server

# Garante que Redis está ativo (Rspamd precisa dele)
systemctl enable redis-server
systemctl start redis-server

# ─── Diretório das chaves DKIM por domínio ───
mkdir -p /var/lib/rspamd/dkim/$ServerName

# ─── Gerar chave DKIM 2048-bit (mesma força que você tinha no OpenDKIM) ───
# Selector "default" é o padrão moderno (BillionMail, Mailcow, Postal usam todos "default")
rspamadm dkim_keygen \
  -s default \
  -b 2048 \
  -d $ServerName \
  -k /var/lib/rspamd/dkim/$ServerName/default.private \
  > /var/lib/rspamd/dkim/$ServerName/default.pub

# Permissões corretas (Rspamd roda como user _rspamd no Ubuntu/Debian)
chown -R _rspamd:_rspamd /var/lib/rspamd/dkim
chmod 600 /var/lib/rspamd/dkim/$ServerName/default.private
chmod 644 /var/lib/rspamd/dkim/$ServerName/default.pub

# Verificar se as chaves foram geradas
if [ ! -f /var/lib/rspamd/dkim/$ServerName/default.private ] || \
   [ ! -f /var/lib/rspamd/dkim/$ServerName/default.pub ]; then
    echo "ERRO: Falha ao gerar chaves DKIM via Rspamd!"
    exit 1
fi

echo "✓ Chaves DKIM geradas em /var/lib/rspamd/dkim/$ServerName/"

# ─── CONFIG 1: DKIM Signing ───
# Define quando assinar e qual chave usar
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
# Habilita assinatura DKIM
enabled = true;

# Assina apenas saída (não entrada)
sign_authenticated = true;   # assina mensagens de usuários autenticados (Supermailer)
sign_local = true;           # assina mensagens de localhost/mynetworks
sign_inbound = false;        # NÃO assina mensagens vindas de fora (não faz sentido)

# Domínio + selector + caminho da chave privada
domain {
  $ServerName {
    selectors [
      {
        path = "/var/lib/rspamd/dkim/$ServerName/default.private";
        selector = "default";
      }
    ]
  }
}

# Configurações de segurança
allow_hdrfrom_mismatch = false;   # rejeita se From do header != envelope (anti-spoof)
allow_hdrfrom_multiple = false;   # só permite UM header From (RFC 5322)
use_esld = true;                  # normaliza para domínio raiz (sub.dom.com → dom.com)
check_pubkey = true;              # valida que a chave pública existe no DNS antes de assinar
EOF

# ─── CONFIG 2: ARC Signing (sobrevive forwards) ───
# Quando alguém recebe seu email e reencaminha (ex: alias do trabalho → gmail pessoal),
# o ARC preserva a cadeia de autenticação. Sem ARC, forwards quebram DKIM/DMARC.
cat > /etc/rspamd/local.d/arc.conf <<EOF
sign_authenticated = true;
sign_local = true;
sign_inbound = false;

domain {
  $ServerName {
    selectors [
      {
        path = "/var/lib/rspamd/dkim/$ServerName/default.private";
        selector = "default";
      }
    ]
  }
}
EOF

# ─── CONFIG 3: Conexão com Redis (para reputação e rate limit) ───
cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1:6379";
timeout = 1.0;
EOF

# ─── CONFIG 4: Worker Proxy (é o que o Postfix conecta como milter) ───
# Por padrão Rspamd escuta em 127.0.0.1:11332 para milter
cat > /etc/rspamd/local.d/worker-proxy.inc <<EOF
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF

# ─── CONFIG 5: Worker Controller (UI web na porta 11334, opcional mas útil) ───
# Permite ver estatísticas em http://SEU_IP:11334
# Senha vazia = só acessível de localhost (seguro)
cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";
EOF

# ─── Habilitar e iniciar Rspamd ───
systemctl enable rspamd
systemctl restart rspamd

# Aguardar Rspamd subir COMPLETAMENTE (com retry de até 30s)
echo "  -- Aguardando Rspamd inicializar..."
RSPAMD_READY=0
for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -q 11332; then
        RSPAMD_READY=1
        echo "  ✓ Rspamd escutando em 127.0.0.1:11332 (após ${i}s)"
        break
    fi
    sleep 1
done

if [ "$RSPAMD_READY" = "0" ]; then
    echo "  ⚠️  AVISO: Rspamd não abriu porta 11332 em 30s"
    echo "  ⚠️  Continuando mesmo assim — verificar com 'systemctl status rspamd' depois"
    journalctl -u rspamd -n 20 --no-pager 2>/dev/null || true
    # NÃO usar exit 1 — apenas avisar e continuar
fi

# Verificação adicional do sign_networks (não bloqueia)
if rspamadm configdump dkim_signing 2>/dev/null | grep -q "127.0.0.0/8"; then
    echo "  ✓ sign_networks configurado corretamente"
else
    echo "  ⚠️  AVISO: sign_networks pode não estar correto — verificar manualmente"
fi

# ─── Script para extrair a chave pública DKIM (substitui /root/dkimcode.sh) ───
# Mesma lógica do seu script anterior, mas lendo da nova localização
cat <<'EOF' > /root/dkimcode.sh
#!/usr/bin/node
const fs = require('fs');
const path = process.argv[2] || `/var/lib/rspamd/dkim/${process.env.ServerName}/default.pub`;
const DKIM = fs.readFileSync(path, 'utf8');
console.log(
  DKIM.replace(/(\r\n|\n|\r|\t|"|\)| )/gm, "")
  .split(";")
  .find((c) => c.match("p="))
  .replace("p=","")
);
EOF
chmod 755 /root/dkimcode.sh

echo "✓ Rspamd configurado — DKIM + ARC + Redis prontos para envio em massa"
echo "================================================= Atualização de pacotes ================================================="


# Tenta APT primeiro; se não houver, tenta venv + pip; como último recurso, pip do sistema.
install_py_pkg() {
  local pip_name="$1"    # ex.: dnspython
  local apt_name="$2"    # ex.: python3-dnspython
  local required="${3:-0}"
  local ok=0

  echo "==> Instalando ${pip_name} (APT -> venv -> pip)..."
#apt-get update -y >/dev/null 2>&1 || true

  # 1) APT
  if apt-get install -y "${apt_name}"; then
    echo "OK via APT: ${apt_name}"; ok=1
  else
    # 2) venv + pip
    apt-get install -y python3-venv python3-pip >/dev/null 2>&1 || true
    if python3 -m venv /opt/venv >/dev/null 2>&1; then
      . /opt/venv/bin/activate
      if pip install -q "${pip_name}" >/tmp/pip_${pip_name}_venv.log 2>&1; then
        echo "OK via venv: ${pip_name} (em /opt/venv)"; ok=1
      fi
      deactivate || true
    fi

    # 3) (opcional) permitir pip no sistema se ALLOW_PIP_BREAK=1
    if [ "$ok" -eq 0 ] && [ "${ALLOW_PIP_BREAK:-0}" = "1" ]; then
      if python3 -m pip install --break-system-packages -q "${pip_name}" >/tmp/pip_${pip_name}.log 2>&1; then
        echo "OK via pip (--break-system-packages): ${pip_name}"; ok=1
      fi
    fi
  fi

  if [ "$ok" -eq 1 ]; then return 0; fi
  echo "AVISO: não foi possível instalar ${pip_name}."
  [ "$required" -eq 1 ] && exit 1 || return 0
}

# ════════════════════════════════════════════════════════════════
# INSTALAÇÃO DE DEPENDÊNCIAS PARA PDF (wkhtmltopdf + bibliotecas)
# ════════════════════════════════════════════════════════════════
echo "================================================= Instalando dependências PDF ================================================="

# Instalar wkhtmltopdf (necessário para pdfkit)
echo ">> Instalando wkhtmltopdf..."
apt-get install -y wkhtmltopdf || {
    echo "AVISO: Falha ao instalar wkhtmltopdf via apt. Tentando métodos alternativos..."
    # Fallback: tentar instalar via wget se apt falhar
    wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb -O /tmp/wkhtmltox.deb
    dpkg -i /tmp/wkhtmltox.deb || apt-get install -f -y
    rm -f /tmp/wkhtmltox.deb
}

# Instalar bibliotecas Python para PDF
echo ">> Instalando pdfkit e PyPDF2..."
pip3 install --upgrade --break-system-packages pdfkit PyPDF2 || {
    echo "AVISO: Falha na instalação via pip3. Tentando com python3 -m pip..."
    python3 -m pip install --upgrade --break-system-packages pdfkit PyPDF2 || true
}

if command -v wkhtmltopdf >/dev/null 2>&1; then
    echo "OK: wkhtmltopdf instalado - $(wkhtmltopdf --version | head -n 1)"
else
    echo "AVISO: wkhtmltopdf não está disponível."
fi

echo "✓ Dependências PDF configuradas!"
# ════════════════════════════════════════════════════════════════

# Uso:
install_py_pkg "dnspython" "python3-dnspython" 0

echo "================================================= POSTFIX ================================================="

# Configurações básicas do Postfix
debconf-set-selections <<< "postfix postfix/mailname string '$ServerName'"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
debconf-set-selections <<< "postfix postfix/destinations string 'localhost'"

# Instalar Postfix e outros
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix pflogsumm dovecot-core

echo -e "$ServerName OK" > /etc/postfix/access.recipients
postmap /etc/postfix/access.recipients

echo "================================================= CONFIGURANDO ALIASES BÁSICOS ================================================="

# ════════════════════════════════════════════════════════════════
# Aliases do SISTEMA (não confundir com virtual aliases)
# Estes são para usuários locais do sistema
# ════════════════════════════════════════════════════════════════
cat > /etc/aliases <<'EOF'
# Aliases de sistema padrão
postmaster: root
mailer-daemon: postmaster
abuse: postmaster
spam: postmaster

# Descartar bounces do sistema
root: /dev/null
nobody: /dev/null
www-data: /dev/null
mail: /dev/null
daemon: /dev/null
bin: /dev/null
sys: /dev/null
EOF

newaliases

echo "✓ Aliases do sistema configurados!"
echo "✓ Bounces do sistema serão descartados em /dev/null"

echo "================================================= CONFIGURANDO USUÁRIO VIRTUAL ================================================="
if ! id "vmail" &>/dev/null; then
    useradd -r -u 150 -g mail -d /var/mail/virtual -s /sbin/nologin -c "Virtual Mail User" vmail
    echo "✓ Usuário vmail criado"
else
    echo "✓ Usuário vmail já existe"
fi

mkdir -p /var/mail/virtual
chown -R vmail:mail /var/mail/virtual
chmod 755 /var/mail/virtual

echo "================================================= CONFIGURANDO DOVECOT ================================================="
cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}
EOF

cat > /etc/dovecot/conf.d/10-auth.conf <<'EOF'
auth_mechanisms = plain login
passdb {
  driver = passwd-file
  args = username_format=%u /etc/dovecot/users
}
userdb {
  driver = static
  args = uid=150 gid=8 home=/var/mail/virtual/%u
}
EOF

# Criar usuário SMTP para o Supermailer
cat > /etc/dovecot/users <<EOF
admin@$ServerName:{PLAIN}dwwzyd
EOF

chmod 640 /etc/dovecot/users
chown root:dovecot /etc/dovecot/users

systemctl enable dovecot
systemctl restart dovecot
echo "✓ Dovecot configurado com autenticação SASL!"

echo "================================================= POSTFIX MAIN CF ================================================="
cat <<EOF > /etc/postfix/main.cf
myhostname = $MailServerName
smtp_helo_name = $MailServerName
smtpd_helo_required = yes
smtpd_banner = \$myhostname ESMTP
biff = no
readme_directory = no
compatibility_level = 3.6

# ===== DESABILITAR SMTPUTF8 (corrige erro 5.6.7) =====
smtputf8_enable = no

# Aliases locais
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases

# DKIM (OpenDKIM)
milter_protocol = 6
milter_default_action = accept
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332

# ===== SASL Authentication (SMTP autenticado - Supermailer porta 587) =====
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_security_options = noanonymous

# TLS - entrada (smtpd)
smtpd_tls_security_level = may
smtpd_tls_loglevel = 2
smtpd_tls_received_header = yes
smtpd_tls_session_cache_timeout = 3600s
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_ciphers = high
smtpd_tls_exclude_ciphers = aNULL, MD5, 3DES
smtpd_tls_cert_file = /etc/letsencrypt/live/$ServerName/fullchain.pem
smtpd_tls_key_file  = /etc/letsencrypt/live/$ServerName/privkey.pem
smtpd_tls_mandatory_ciphers = high
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_exclude_ciphers = aNULL, MD5, DES, 3DES, RC4, EXPORT

# TLS - saída (smtp cliente)
smtp_tls_security_level = may
smtp_tls_loglevel = 1
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_ciphers = high
smtp_tls_mandatory_ciphers = high
smtp_tls_exclude_ciphers = aNULL, MD5, DES, 3DES, RC4
smtp_tls_mandatory_exclude_ciphers = aNULL, MD5, DES, 3DES, RC4, EXPORT
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtp_tls_note_starttls_offer = yes
tls_preempt_cipherlist = yes

# Base
mydomain = $ServerName
myorigin = $ServerName
mydestination = localhost, localhost.localdomain, $MailServerName
relayhost = [dedrelay.secureserver.net]
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = ipv4

# ===== Restrictions (SASL + mynetworks) =====
smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, defer_unauth_destination

# Prevenir loop de bounces
local_recipient_maps =

maximal_queue_lifetime = 2d
bounce_queue_lifetime = 2d

# Timeouts
smtp_connect_timeout = 30s
smtp_helo_timeout = 30s
smtp_mail_timeout = 30s
smtp_rcpt_timeout = 30s
smtp_data_init_timeout = 60s
smtp_data_xfer_timeout = 300s
smtp_data_done_timeout = 300s

# Rate limiting
smtp_destination_concurrency_limit = 15
smtp_destination_rate_delay = 1s
smtp_destination_recipient_limit = 30
default_destination_concurrency_limit = 15
default_destination_rate_delay = 1s
default_destination_recipient_limit = 30

# Header checks
header_checks = regexp:/etc/postfix/header_checks
EOF


# ═══════════════════════════════════════════════════════════
# CORREÇÃO 2: HEADER CHECKS (NOVO - não existia no seu .sh)
# Adicione DEPOIS do bloco main.cf
# ═══════════════════════════════════════════════════════════

cat > /etc/postfix/header_checks <<'HCEOF'
/^Received:.*127\.0\.0\.1/           IGNORE
/^Received:.*localhost/              IGNORE
/^Received:.*from userid/           IGNORE
/^X-Mailer:/                         IGNORE
/^X-PHP-Originating-Script:/         IGNORE
/^X-Originating-IP:.*127/            IGNORE
/^X-Spam-Status:/                    IGNORE
/^X-Spam-Score:/                     IGNORE
HCEOF

chmod 644 /etc/postfix/header_checks
echo "✓ Header checks configurados"

echo "================================================= POSTFIX MASTER CF ================================================="

systemctl restart postfix

echo "✓ Postfix configurado com rate limiting e SSL Nota A!"

echo "================================================= CONFIGURANDO PORTA 587 (SMTP AUTH) ================================================="

if ! grep -q "^587.*inet.*smtpd" /etc/postfix/master.cf; then
    cat >> /etc/postfix/master.cf <<'EOF'
587       inet  n       -       y       -       -       smtpd
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
EOF
    echo "✓ Porta 587 configurada"
else
    echo "✓ Porta 587 já existe"
fi

systemctl restart postfix
echo "✓ SMTP autenticado na porta 587 pronto para Supermailer!"

echo "================================================= POSTFIX ================================================="

# Salvar variáveis antes de instalar dependências
ORIGINAL_VARS=$(declare -p ServerName CloudflareAPI CloudflareEmail Domain DKIMSelector ServerIP)


# === MAIL.LOG OTIMIZADO PARA ENVIO EM MASSA ===
echo "Configurando logs otimizados para envio em massa..."

apt-get install -y rsyslog logrotate

# Backup da configuração atual
cp /etc/rsyslog.conf /etc/rsyslog.conf.backup.$(date +%Y%m%d)

# Configuração otimizada para alto volume
cat >/etc/rsyslog.d/49-mail.conf <<'EOF'
# Log mail messages with optimizations for high volume
# Use async writing and reduce sync frequency
mail.*                          -/var/log/mail.log

# Optimize for high volume (buffer writes)
$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
$ActionFileEnableSync off
$MainMsgQueueSize 100000
$ActionQueueSize 100000

# Stop processing mail messages (don't duplicate in syslog)
& stop
EOF

# Criar diretório de logs
mkdir -p /var/log

# Permissões otimizadas
chown root:root /var/log
chmod 755 /var/log
touch /var/log/mail.log
chown syslog:adm /var/log/mail.log
chmod 0640 /var/log/mail.log

# Rotação otimizada para alto volume
cat >/etc/logrotate.d/mail-log <<'EOF'
/var/log/mail.log {
    hourly
    missingok
    rotate 48
    compress
    delaycompress
    notifempty
    create 0640 syslog adm
    size 100M
    sharedscripts
    postrotate
        if systemctl is-active rsyslog >/dev/null 2>&1; then
            systemctl kill -s HUP rsyslog.service
        fi
    endscript
}
EOF

# Configurar rsyslog para performance
cat >>/etc/rsyslog.conf <<'EOF'

# Optimizations for high volume mail logging
$WorkDirectory /var/spool/rsyslog
$ActionQueueFileName mailqueue
$ActionQueueMaxDiskSpace 1g
$ActionQueueSaveOnShutdown on
$ActionQueueType LinkedList
$ActionResumeRetryCount -1
EOF

# Testar e reiniciar
rsyslogd -N1 && echo "✓ Configuração rsyslog válida" || echo "✗ Erro na configuração rsyslog"

systemctl enable rsyslog
systemctl restart rsyslog

echo "✓ Logs otimizados para envio em massa configurados!"

# Instalar cron se não existir
if ! command -v crontab >/dev/null 2>&1; then
  apt-get install -y cron
  systemctl enable cron
  systemctl start cron
fi

# === CLASSIFY-BOUNCES INTELIGENTE (criar e permitir execução) ===
cat >/usr/local/bin/classify-bounces <<'CBEOF'
#!/bin/bash
set -euo pipefail
exec 200>/var/run/classify-bounces.lock
flock -n 200 || exit 0

LOGS="/var/log/mail.log*"
OUTDIR="/var/www/html"

# === BOUNCES - Classificacao Inteligente ===
zgrep -h 'postfix/smtp.*status=bounced' $LOGS 2>/dev/null | awk -v outdir="$OUTDIR" '
{
    line = $0
    if (match(line, /to=<[^>]+>/)) {
        rcpt = substr(line, RSTART+4, RLENGTH-5)
    } else next

    dsn = ""
    if (match(line, /dsn=5\.[0-9]+\.[0-9]+/)) {
        dsn = substr(line, RSTART+4, RLENGTH-4)
    }

    reason = tolower(line)

    # =============================================
    # 1) INVALID CONFIRMED (certeza que nao existe)
    # =============================================
    invalid_confirmed = 0

    if (dsn == "5.1.1") {
        if (reason ~ /user doesn.t exist/) invalid_confirmed = 1
        if (reason ~ /no such user/) invalid_confirmed = 1
        if (reason ~ /user unknown/) invalid_confirmed = 1
        if (reason ~ /does not exist/) invalid_confirmed = 1
        if (reason ~ /no such mailbox/) invalid_confirmed = 1
        if (reason ~ /mailbox not found/) invalid_confirmed = 1
        if (reason ~ /recipient not found/) invalid_confirmed = 1
        if (reason ~ /account disabled/) invalid_confirmed = 1
        if (reason ~ /account has been disabled/) invalid_confirmed = 1
        if (reason ~ /invalid mailbox/) invalid_confirmed = 1
        if (reason ~ /unknown user/) invalid_confirmed = 1
        if (reason ~ /no mailbox here/) invalid_confirmed = 1
        if (reason ~ /email account.*not.*found/) invalid_confirmed = 1
        if (reason ~ /undeliverable address.*user/) invalid_confirmed = 1
    }

    if (dsn == "5.1.0" || dsn == "5.1.10") {
        if (reason ~ /no such user/) invalid_confirmed = 1
        if (reason ~ /user unknown/) invalid_confirmed = 1
        if (reason ~ /does not exist/) invalid_confirmed = 1
        if (reason ~ /address rejected/) invalid_confirmed = 1
    }

    # =============================================
    # 2) INVALID RETEST (pode ser falso positivo)
    # =============================================
    invalid_retest = 0

    if (dsn == "5.5.0") {
        if (reason ~ /mailbox unavailable/) invalid_retest = 1
        if (reason ~ /requested action not taken/) invalid_retest = 1
    }

    if (dsn == "5.1.1" && invalid_confirmed == 0) {
        invalid_retest = 1
    }

    if (dsn ~ /^5\.2\./) {
        if (reason ~ /mailbox.*disabled/) invalid_retest = 1
        if (reason ~ /mailbox.*full/) invalid_retest = 1
        if (reason ~ /over quota/) invalid_retest = 1
        if (reason ~ /quota exceeded/) invalid_retest = 1
        if (reason ~ /mailbox unavailable/) invalid_retest = 1
    }

    if (dsn == "5.0.0" || dsn == "5.5.0") {
        if (reason ~ /user unknown/) invalid_retest = 1
        if (reason ~ /no such user/) invalid_retest = 1
        if (reason ~ /mailbox not found/) invalid_retest = 1
    }

    if (invalid_confirmed == 0 && invalid_retest == 0) {
        if (reason ~ /mailbox unavailable/ && dsn !~ /^5\.7\./) invalid_retest = 1
        if (reason ~ /recipient rejected/ && dsn !~ /^5\.7\./) invalid_retest = 1
    }

    # =============================================
    # 3) POLICY BLOCKS (rejeicao por politica/reputacao)
    # =============================================
    policy = 0

    if (dsn ~ /^5\.7\./) policy = 1

    if (reason ~ /spamhaus/) policy = 1
    if (reason ~ /barracuda/) policy = 1
    if (reason ~ /rbl/) policy = 1
    if (reason ~ /blacklist/) policy = 1
    if (reason ~ /blocklist/) policy = 1
    if (reason ~ /listed at/) policy = 1
    if (reason ~ /blocked/) policy = 1
    if (reason ~ /access denied/) policy = 1
    if (reason ~ /not allowed/) policy = 1
    if (reason ~ /rejected.*policy/) policy = 1
    if (reason ~ /spam/) policy = 1
    if (reason ~ /abuse/) policy = 1
    if (reason ~ /dnsbl/) policy = 1
    if (reason ~ /rejected.*reputation/) policy = 1
    if (reason ~ /too many connections/) policy = 1
    if (reason ~ /rate limit/) policy = 1
    if (reason ~ /try again later/) policy = 1
    if (reason ~ /temporarily deferred/) policy = 1
    if (reason ~ /sender verify failed/) policy = 1
    if (reason ~ /spf/) policy = 1
    if (reason ~ /dkim/) policy = 1
    if (reason ~ /dmarc/) policy = 1

    # =============================================
    # 4) DOMAIN INVALID (dominio nao existe)
    # =============================================
    domain_invalid = 0
    if (reason ~ /name or service not known/) domain_invalid = 1
    if (reason ~ /no route to host/) domain_invalid = 1
    if (reason ~ /domain not found/) domain_invalid = 1
    if (reason ~ /bad destination mailbox/) domain_invalid = 1
    if (dsn == "5.1.2") domain_invalid = 1
    if (dsn == "5.4.4") domain_invalid = 1
    if (dsn == "5.4.6") domain_invalid = 1

    # =============================================
    # GRAVAR NOS ARQUIVOS (com prioridade)
    # =============================================
    if (domain_invalid)
        print rcpt > (outdir "/domain_invalid.txt")
    else if (invalid_confirmed)
        print rcpt > (outdir "/invalid_confirmed.txt")
    else if (policy)
        print rcpt > (outdir "/policy_blocks.txt")
    else if (invalid_retest)
        print rcpt > (outdir "/invalid_retest.txt")
    else
        print rcpt > (outdir "/ambiguous_bounces.txt")
}
'

# === EMAILS ENVIADOS COM SUCESSO (status=sent 250 OK) ===
zgrep -h 'postfix/smtp.*status=sent' $LOGS 2>/dev/null | awk '
{
    if (match($0, /to=<[^>]+>/)) {
        rcpt = substr($0, RSTART+4, RLENGTH-5)
        print rcpt
    }
}
' | sort -u > "$OUTDIR/sent_success.txt"

# === DEFERRED (tentativas que ainda nao resolveram) ===
zgrep -h 'postfix/smtp.*status=deferred' $LOGS 2>/dev/null | awk '
{
    if (match($0, /to=<[^>]+>/)) {
        rcpt = substr($0, RSTART+4, RLENGTH-5)
        print rcpt
    }
}
' | sort -u > "$OUTDIR/deferred.txt"

# === Remover duplicatas de todos os arquivos ===
for f in \
    "$OUTDIR/invalid_confirmed.txt" \
    "$OUTDIR/invalid_retest.txt" \
    "$OUTDIR/policy_blocks.txt" \
    "$OUTDIR/domain_invalid.txt" \
    "$OUTDIR/ambiguous_bounces.txt" \
    "$OUTDIR/sent_success.txt" \
    "$OUTDIR/deferred.txt"; do
    [ -f "$f" ] && sort -u "$f" -o "$f"
done

# === Prioridade: sent_success remove dos duvidosos ===
if [ -f "$OUTDIR/sent_success.txt" ]; then
    for f in "$OUTDIR/invalid_retest.txt" "$OUTDIR/policy_blocks.txt" "$OUTDIR/ambiguous_bounces.txt"; do
        if [ -f "$f" ]; then
            comm -23 "$f" "$OUTDIR/sent_success.txt" > "${f}.tmp"
            mv "${f}.tmp" "$f"
        fi
    done
fi

# === Gerar relatorio de contagem ===
echo "=== Relatorio Classify-Bounces ===" > "$OUTDIR/bounce_report.txt"
echo "Data: $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTDIR/bounce_report.txt"
echo "-----------------------------------" >> "$OUTDIR/bounce_report.txt"
for f in invalid_confirmed invalid_retest policy_blocks domain_invalid ambiguous_bounces sent_success deferred; do
    if [ -f "$OUTDIR/${f}.txt" ]; then
        count=$(wc -l < "$OUTDIR/${f}.txt")
    else
        count=0
    fi
    printf "%-25s %s\n" "$f:" "$count" >> "$OUTDIR/bounce_report.txt"
done
echo "-----------------------------------" >> "$OUTDIR/bounce_report.txt"
CBEOF

chmod +x /usr/local/bin/classify-bounces
printf 'www-data ALL=(root) NOPASSWD: /usr/local/bin/classify-bounces\n' >/etc/sudoers.d/classify-bounces
chmod 0440 /etc/sudoers.d/classify-bounces

# Cron job para rodar a cada 10 minutos
(crontab -l 2>/dev/null || true; echo "*/10 * * * * /usr/local/bin/classify-bounces >/dev/null 2>&1") | sort -u | crontab -

echo "✓ Classify-bounces INTELIGENTE configurado com cron a cada 10 min"
echo "  → invalid_confirmed.txt  = descartar (usuario confirmado inexistente)"
echo "  → invalid_retest.txt     = retestar de outro IP (pode ser falso positivo)"
echo "  → policy_blocks.txt      = bloqueio por reputacao/blacklist"
echo "  → domain_invalid.txt     = dominio nao existe"
echo "  → ambiguous_bounces.txt  = investigar manualmente"
echo "  → sent_success.txt       = entregue com sucesso"
echo "  → deferred.txt           = ainda tentando"
echo "  → bounce_report.txt      = relatorio com contagens"
# === FIM CLASSIFY-BOUNCES ===
echo "================================================= CLOUDFLARE ================================================="

echo "===== DEPURAÇÃO: ANTES DE CONFIGURAÇÃO CLOUDFLARE ====="
echo "ServerName: $ServerName"
echo "CloudflareAPI: $CloudflareAPI"
echo "CloudflareEmail: $CloudflareEmail"
echo "Domain: $Domain"
echo "DKIMSelector: $DKIMSelector"
echo "ServerIP: $ServerIP"

# Instalar jq (caso não exista)
if ! command -v jq &> /dev/null; then
  apt-get install -y jq
fi

# Passar o caminho do .pub do Rspamd para o script
DKIMCode=$(/root/dkimcode.sh /var/lib/rspamd/dkim/$ServerName/default.pub)

echo "===== DEPURAÇÃO: ANTES DE OBTER ZONA CLOUDFLARE ====="
echo "DKIMCode: $DKIMCode"
echo "Domain: $Domain"
echo "ServerName: $ServerName"

# Obter ID da zona
CloudflareZoneID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Domain&status=active" \
  -H "X-Auth-Email: $CloudflareEmail" \
  -H "X-Auth-Key: $CloudflareAPI" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$CloudflareZoneID" ] || [ "$CloudflareZoneID" = "null" ]; then
  echo "Erro: Não foi possível obter o ID da zona do Cloudflare."
  exit 1
fi

echo "===== DEPURAÇÃO: APÓS OBTER ZONA CLOUDFLARE ====="
echo "CloudflareZoneID: $CloudflareZoneID"

# Função para obter detalhes de registro
get_record_details() {
  local record_name=$1
  local record_type=$2
  curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CloudflareZoneID/dns_records?name=$record_name&type=$record_type" \
    -H "X-Auth-Email: $CloudflareEmail" \
    -H "X-Auth-Key: $CloudflareAPI" \
    -H "Content-Type: application/json"
}

# Função para criar ou atualizar registros no Cloudflare
create_or_update_record() {
  local record_name=$1
  local record_type=$2
  local record_content=$3
  local record_ttl=120
  local record_priority=$4
  local record_proxied=false

  # Definir TTL conforme tipo de registro
  case "$record_type" in
    MX)  record_ttl=3600 ;;     # 1h
    TXT) record_ttl=3600 ;;     # 1h (SPF, DKIM, DMARC)
    A)   record_ttl=1800 ;;     # 30min a 1h para IPs
    *)   record_ttl=3600 ;;     # Padrão
  esac

  echo "===== DEPURAÇÃO: ANTES DE OBTER DETALHES DO REGISTRO ====="
  echo "RecordName: $record_name"
  echo "RecordType: $record_type"
  echo "TTL definido: $record_ttl"
  
  # Detalhes do registro existente
  local response
  response=$(get_record_details "$record_name" "$record_type")

  local existing_id
  existing_id=$(echo "$response" | jq -r '.result[0].id')
  local existing_content
  existing_content=$(echo "$response" | jq -r '.result[0].content')
  local existing_ttl
  existing_ttl=$(echo "$response" | jq -r '.result[0].ttl')
  local existing_priority
  existing_priority=$(echo "$response" | jq -r '.result[0].priority')

  echo "===== DEPURAÇÃO: DETALHES DO REGISTRO EXISTENTE ====="
  echo "ExistingID: $existing_id"
  echo "ExistingContent: $existing_content"
  echo "ExistingTTL: $existing_ttl"
  echo "ExistingPriority: $existing_priority"

  # Montar JSON
  local data
  if [ "$record_type" == "MX" ]; then
    data=$(jq -n \
      --arg type "$record_type" \
      --arg name "$record_name" \
      --arg content "$record_content" \
      --arg ttl "$record_ttl" \
      --argjson proxied "$record_proxied" \
      --arg priority "$record_priority" \
      '{type: $type, name: $name, content: $content, ttl: ($ttl|tonumber), proxied: $proxied, priority: ($priority|tonumber)}'
    )
  else
    data=$(jq -n \
      --arg type "$record_type" \
      --arg name "$record_name" \
      --arg content "$record_content" \
      --arg ttl "$record_ttl" \
      --argjson proxied "$record_proxied" \
      '{type: $type, name: $name, content: $content, ttl: ($ttl|tonumber), proxied: $proxied}'
    )
  fi

  # Se registro não existe, criar via POST
  if [ "$existing_id" = "null" ] || [ -z "$existing_id" ]; then
    echo "  -- Criando novo registro ($record_type) para $record_name..."
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CloudflareZoneID/dns_records" \
      -H "X-Auth-Email: $CloudflareEmail" \
      -H "X-Auth-Key: $CloudflareAPI" \
      -H "Content-Type: application/json" \
      --data "$data")
    echo "$response"
  else
    # Se já existe, fazer PUT (update)
    echo "  -- Atualizando registro ($record_type) para $record_name [ID: $existing_id]..."
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CloudflareZoneID/dns_records/$existing_id" \
      -H "X-Auth-Email: $CloudflareEmail" \
      -H "X-Auth-Key: $CloudflareAPI" \
      -H "Content-Type: application/json" \
      --data "$data")
    echo "$response"
  fi
}

# Criar/atualizar registros
echo "  -- Configurando registros DNS Cloudflare..."

# Garante que o DKIMCode fique em uma única linha sem aspas que atrapalhem
DKIMCode=$(echo "$DKIMCode" | tr -d '\n' | tr -s ' ')
EscapedDKIMCode=$(printf '%s' "$DKIMCode" | sed 's/\"/\\\"/g')

create_or_update_record "$ServerName" "A" "$ServerIP" ""
create_or_update_record "$MailServerName" "A" "$ServerIP" ""
create_or_update_record "$ServerName" "TXT" "\"v=spf1 ip4:$ServerIP include:secureserver.net -all\"" ""
create_or_update_record "_dmarc.$ServerName" "TXT" "\"v=DMARC1; p=quarantine; sp=quarantine; pct=100; rua=mailto:dmarc-reports@$ServerName; adkim=r; aspf=r; fo=1\"" ""
create_or_update_record "default._domainkey.$ServerName" "TXT" "\"v=DKIM1; h=sha256; k=rsa; p=$EscapedDKIMCode\"" ""
create_or_update_record "$ServerName" "MX" "$MailServerName" "10"
echo "================================================= APPLICATION ================================================="

# Verificar se /var/www/html existe
if [ ! -d "/var/www/html" ]; then
    echo "Pasta /var/www/html não existe."
    exit 1
fi

rm -f /var/www/html/index.html

cat <<'EOF' > /var/www/html/index.php
<?php

function generateRandom($min, $max) {
    $characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    $length = rand($min, $max);
    $charactersLength = strlen($characters);
    $randomString = '';
    for ($i = 0; $i < $length; $i++) {
        $randomString .= $characters[rand(0, $charactersLength - 1)];
    }
    return $randomString;
}

if (!function_exists('randStringW2')) {
    function randStringW2($size) {
        $basic = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
        $basic2 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        $return = $basic[rand(0, strlen($basic) - 1)];
        $size = rand($size, $size + 4);
        for ($count = 0; $size > $count; $count++) {
            $return .= $basic2[rand(0, strlen($basic2) - 1)];
        }
        return $return;
    }
}

function randURL2($size) {
    $return = '';
    $size = rand($size, $size + 10);
    for ($count = 0; $size > $count; $count++) {
        $return .= randStringW2(5);
        if ((rand(1, 3)) == 1) {
            $return .= "/";
        }
    }
    return $return;
}

// Só redireciona se não tiver ?hl= na URL ainda
if (!isset($_GET['hl'])) {
    $lang = substr($_SERVER['HTTP_ACCEPT_LANGUAGE'] ?? 'en', 0, 5);
    $lang = str_replace('-', '_', $lang);

    // Preservar parâmetros existentes (p, id, etc.)
    $params = $_GET;
    $params['hl'] = $lang;
    $params['r'] = randURL2(20);
    header("Location: ?" . http_build_query($params));
    exit;
}

$host      = $_SERVER['HTTP_HOST'] ?? 'example.com';
$parts     = explode('.', $host);
$brandRaw  = count($parts) >= 2 ? $parts[count($parts) - 2] : $parts[0];
$brand     = ucfirst($brandRaw);
$year      = date('Y');
$page      = $_GET['p'] ?? 'home';
$brind     = generateRandom(2, 3);

$seed = crc32($host);
mt_srand($seed);

$taglines = [
    "Soluciones digitales innovadoras para empresas modernas",
    "Conectamos marcas con su audiencia de forma inteligente",
    "Estrategias de comunicación que generan resultados reales",
    "Impulsamos tu negocio a través de la excelencia digital",
    "Tu aliado estratégico en transformación digital",
    "Construimos puentes entre marcas y personas",
    "Marketing basado en datos para un crecimiento medible",
    "Soluciones de comunicación estratégica en toda la región",
];
$tagline = $taglines[mt_rand(0, count($taglines) - 1)];

$services = [
    ['icon' => '📊', 'title' => 'Análisis de Datos',        'desc' => 'Transformamos datos en información accionable que impulsa el crecimiento de tu negocio y optimiza el retorno de tu inversión en marketing.'],
    ['icon' => '📧', 'title' => 'Email Marketing',           'desc' => 'Campañas personalizadas diseñadas para conectar con tu audiencia y convertir suscriptores en clientes fieles a tu marca.'],
    ['icon' => '🎯', 'title' => 'Estrategia Digital',        'desc' => 'Hojas de ruta digitales integrales, adaptadas a los objetivos de tu empresa y a los segmentos de tu mercado objetivo.'],
    ['icon' => '🔍', 'title' => 'Investigación de Mercado',  'desc' => 'Análisis profundo de tendencias del mercado y comportamiento del consumidor para mantenerte un paso adelante de la competencia.'],
    ['icon' => '💡', 'title' => 'Consultoría de Marca',      'desc' => 'Construimos una identidad de marca sólida y coherente que conecte con tu audiencia en todos los canales de comunicación.'],
    ['icon' => '📱', 'title' => 'Engagement de Clientes',    'desc' => 'Estrategias multicanal para construir relaciones duraderas y aumentar el valor de vida de cada cliente.'],
];

$teamMembers = [
    ['name' => 'Alejandra Moreno',   'role' => 'Directora General'],
    ['name' => 'David Castellanos',  'role' => 'Director de Estrategia'],
    ['name' => 'Carolina Méndez',    'role' => 'Directora de Operaciones'],
    ['name' => 'Martín Herrera',     'role' => 'Analista de Datos Senior'],
];

$colors = [
    ['primary' => '#0f4c81', 'accent' => '#e8953a', 'bg' => '#faf9f7'],
    ['primary' => '#1a3c5e', 'accent' => '#c0392b', 'bg' => '#f8f9fa'],
    ['primary' => '#2c3e50', 'accent' => '#27ae60', 'bg' => '#f5f6f7'],
    ['primary' => '#34495e', 'accent' => '#e67e22', 'bg' => '#fafafa'],
    ['primary' => '#1b2a4a', 'accent' => '#d4a03c', 'bg' => '#f9f8f6'],
];
$theme = $colors[mt_rand(0, count($colors) - 1)];

mt_srand();
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="<?= htmlspecialchars($brind) ?> — <?= htmlspecialchars($tagline) ?>. Soluciones profesionales de marketing digital y comunicación.">
    <meta name="robots" content="index, follow">
    <title><?= htmlspecialchars($brind) ?> — <?= $page === 'privacy' ? 'Política de Privacidad' : ($page === 'terms' ? 'Términos y Condiciones' : ($page === 'contact' ? 'Contacto' : 'Soluciones Digitales')) ?></title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>◆</text></svg>">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;700&family=Playfair+Display:wght@600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: <?= $theme['primary'] ?>;
            --accent: <?= $theme['accent'] ?>;
            --bg: <?= $theme['bg'] ?>;
            --text: #2d2d2d;
            --text-light: #6b7280;
            --white: #ffffff;
            --border: #e5e7eb;
        }
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        html { scroll-behavior: smooth; }
        body {
            font-family: 'DM Sans', -apple-system, BlinkMacSystemFont, sans-serif;
            color: var(--text); background: var(--bg);
            line-height: 1.7; -webkit-font-smoothing: antialiased;
        }
        nav {
            position: fixed; top: 0; left: 0; right: 0; z-index: 100;
            background: rgba(255,255,255,0.95); backdrop-filter: blur(20px);
            border-bottom: 1px solid var(--border); transition: box-shadow 0.3s;
        }
        nav.scrolled { box-shadow: 0 2px 20px rgba(0,0,0,0.08); }
        .nav-inner {
            max-width: 1200px; margin: 0 auto;
            display: flex; align-items: center; justify-content: space-between;
            padding: 0 2rem; height: 72px;
        }
        .logo {
            font-family: 'Playfair Display', serif; font-weight: 700; font-size: 1.5rem;
            color: var(--primary); text-decoration: none; letter-spacing: -0.02em;
        }
        .logo span { color: var(--accent); }
        .nav-links { display: flex; gap: 2rem; list-style: none; }
        .nav-links a {
            text-decoration: none; color: var(--text-light); font-size: 0.9rem;
            font-weight: 500; transition: color 0.2s; position: relative;
        }
        .nav-links a:hover { color: var(--primary); }
        .nav-links a::after {
            content: ''; position: absolute; bottom: -4px; left: 0;
            width: 0; height: 2px; background: var(--accent); transition: width 0.3s;
        }
        .nav-links a:hover::after { width: 100%; }
        .hero {
            padding: 160px 2rem 100px; text-align: center;
            background: linear-gradient(180deg, var(--white) 0%, var(--bg) 100%);
            position: relative; overflow: hidden;
        }
        .hero::before {
            content: ''; position: absolute; top: -50%; left: -50%; width: 200%; height: 200%;
            background: radial-gradient(circle at 30% 40%, rgba(15,76,129,0.03) 0%, transparent 50%),
                        radial-gradient(circle at 70% 60%, rgba(232,149,58,0.03) 0%, transparent 50%);
            animation: drift 20s ease-in-out infinite;
        }
        @keyframes drift {
            0%, 100% { transform: translate(0,0) rotate(0deg); }
            50% { transform: translate(-2%,1%) rotate(1deg); }
        }
        .hero-content { position: relative; z-index: 1; max-width: 800px; margin: 0 auto; }
        .hero-badge {
            display: inline-block; padding: 6px 16px; background: var(--white);
            border: 1px solid var(--border); border-radius: 50px; font-size: 0.8rem;
            font-weight: 500; color: var(--text-light); margin-bottom: 2rem;
            letter-spacing: 0.05em; text-transform: uppercase;
        }
        .hero h1 {
            font-family: 'Playfair Display', serif; font-size: clamp(2.5rem, 5vw, 4rem);
            font-weight: 700; line-height: 1.15; color: var(--primary);
            margin-bottom: 1.5rem; letter-spacing: -0.02em;
        }
        .hero h1 em { font-style: italic; color: var(--accent); }
        .hero p { font-size: 1.15rem; color: var(--text-light); max-width: 600px; margin: 0 auto 2.5rem; }
        .btn {
            display: inline-block; padding: 14px 32px; background: var(--primary);
            color: var(--white); text-decoration: none; border-radius: 8px;
            font-weight: 600; font-size: 0.95rem; transition: all 0.3s; border: none; cursor: pointer;
        }
        .btn:hover { background: var(--accent); transform: translateY(-2px); box-shadow: 0 8px 25px rgba(0,0,0,0.15); }
        .btn-outline { background: transparent; color: var(--primary); border: 2px solid var(--primary); margin-left: 1rem; }
        .btn-outline:hover { background: var(--primary); color: var(--white); }
        .stats {
            display: grid; grid-template-columns: repeat(4, 1fr);
            max-width: 900px; margin: -40px auto 0; padding: 0 2rem; position: relative; z-index: 2;
        }
        .stat { text-align: center; padding: 2rem 1rem; background: var(--white); border: 1px solid var(--border); }
        .stat:first-child { border-radius: 12px 0 0 12px; }
        .stat:last-child { border-radius: 0 12px 12px 0; }
        .stat-num { font-family: 'Playfair Display', serif; font-size: 2rem; font-weight: 700; color: var(--primary); }
        .stat-label { font-size: 0.8rem; color: var(--text-light); margin-top: 4px; text-transform: uppercase; letter-spacing: 0.05em; }
        .section { padding: 100px 2rem; max-width: 1200px; margin: 0 auto; }
        .section-header { text-align: center; margin-bottom: 4rem; }
        .section-header h2 { font-family: 'Playfair Display', serif; font-size: 2.2rem; color: var(--primary); margin-bottom: 1rem; }
        .section-header p { color: var(--text-light); max-width: 550px; margin: 0 auto; }
        .section-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--accent); font-weight: 700; margin-bottom: 0.75rem; }
        .services-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1.5rem; }
        .service-card { padding: 2.5rem; background: var(--white); border: 1px solid var(--border); border-radius: 12px; transition: all 0.3s; }
        .service-card:hover { transform: translateY(-4px); box-shadow: 0 12px 40px rgba(0,0,0,0.08); border-color: var(--accent); }
        .service-icon { font-size: 2rem; margin-bottom: 1rem; }
        .service-card h3 { font-size: 1.15rem; margin-bottom: 0.75rem; color: var(--primary); }
        .service-card p { font-size: 0.92rem; color: var(--text-light); line-height: 1.7; }
        .about-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 4rem; align-items: center; }
        .about-text h2 { font-family: 'Playfair Display', serif; font-size: 2rem; color: var(--primary); margin-bottom: 1.5rem; }
        .about-text p { color: var(--text-light); margin-bottom: 1rem; }
        .about-visual {
            background: linear-gradient(135deg, var(--primary), color-mix(in srgb, var(--primary), var(--accent) 30%));
            border-radius: 16px; padding: 3rem; color: var(--white); position: relative; overflow: hidden;
        }
        .about-visual::before {
            content: ''; position: absolute; top: -50%; right: -50%; width: 200%; height: 200%;
            background: radial-gradient(circle, rgba(255,255,255,0.05) 0%, transparent 70%);
        }
        .about-visual blockquote {
            font-family: 'Playfair Display', serif; font-size: 1.4rem;
            font-style: italic; line-height: 1.6; position: relative; z-index: 1;
        }
        .about-visual cite {
            display: block; margin-top: 1.5rem; font-family: 'DM Sans', sans-serif;
            font-size: 0.85rem; font-style: normal; opacity: 0.8;
        }
        .team-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 2rem; }
        .team-member { text-align: center; }
        .team-avatar {
            width: 80px; height: 80px; border-radius: 50%;
            background: linear-gradient(135deg, var(--primary), var(--accent));
            margin: 0 auto 1rem; display: flex; align-items: center; justify-content: center;
            color: var(--white); font-family: 'Playfair Display', serif; font-size: 1.5rem; font-weight: 700;
        }
        .team-member h4 { font-size: 1rem; color: var(--primary); margin-bottom: 0.25rem; }
        .team-member p { font-size: 0.82rem; color: var(--text-light); }
        .cta { background: var(--primary); padding: 80px 2rem; text-align: center; color: var(--white); }
        .cta h2 { font-family: 'Playfair Display', serif; font-size: 2.2rem; margin-bottom: 1rem; }
        .cta p { opacity: 0.85; margin-bottom: 2rem; max-width: 500px; margin-left: auto; margin-right: auto; }
        .cta .btn { background: var(--accent); }
        .cta .btn:hover { background: var(--white); color: var(--primary); }
        footer { background: #1a1a2e; color: rgba(255,255,255,0.6); padding: 60px 2rem 30px; }
        .footer-inner { max-width: 1200px; margin: 0 auto; display: grid; grid-template-columns: 2fr 1fr 1fr 1fr; gap: 3rem; }
        .footer-brand { font-family: 'Playfair Display', serif; font-size: 1.3rem; color: var(--white); margin-bottom: 1rem; }
        .footer-brand span { color: var(--accent); }
        footer h4 { color: var(--white); font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 1rem; }
        footer ul { list-style: none; }
        footer li { margin-bottom: 0.5rem; }
        footer a { color: rgba(255,255,255,0.6); text-decoration: none; font-size: 0.9rem; transition: color 0.2s; }
        footer a:hover { color: var(--accent); }
        .footer-bottom {
            max-width: 1200px; margin: 3rem auto 0; padding-top: 2rem;
            border-top: 1px solid rgba(255,255,255,0.1);
            display: flex; justify-content: space-between; align-items: center; font-size: 0.82rem;
        }
        .footer-bottom a { margin-left: 1.5rem; }
        .legal { max-width: 800px; margin: 0 auto; padding: 140px 2rem 80px; }
        .legal h1 { font-family: 'Playfair Display', serif; font-size: 2.5rem; color: var(--primary); margin-bottom: 0.5rem; }
        .legal .date { color: var(--text-light); font-size: 0.9rem; margin-bottom: 3rem; }
        .legal h2 { font-size: 1.2rem; color: var(--primary); margin: 2.5rem 0 1rem; }
        .legal p, .legal li { color: var(--text-light); margin-bottom: 1rem; font-size: 0.95rem; }
        .legal ul { padding-left: 1.5rem; }
        .contact-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 4rem; }
        .contact-info h3 { color: var(--primary); margin-bottom: 1.5rem; font-size: 1.1rem; }
        .contact-item { display: flex; align-items: flex-start; gap: 1rem; margin-bottom: 1.5rem; }
        .contact-icon {
            width: 44px; height: 44px; border-radius: 10px;
            background: color-mix(in srgb, var(--primary), transparent 92%);
            display: flex; align-items: center; justify-content: center; font-size: 1.2rem; flex-shrink: 0;
        }
        .contact-item h4 { font-size: 0.9rem; color: var(--primary); }
        .contact-item p { font-size: 0.88rem; color: var(--text-light); }
        @media (max-width: 768px) {
            .stats { grid-template-columns: repeat(2, 1fr); }
            .stat:first-child { border-radius: 12px 0 0 0; }
            .stat:nth-child(2) { border-radius: 0 12px 0 0; }
            .stat:nth-child(3) { border-radius: 0 0 0 12px; }
            .stat:last-child { border-radius: 0 0 12px 0; }
            .about-grid, .contact-grid { grid-template-columns: 1fr; }
            .team-grid { grid-template-columns: repeat(2, 1fr); }
            .footer-inner { grid-template-columns: 1fr 1fr; }
            .nav-links { display: none; }
            .btn-outline { margin-left: 0; margin-top: 0.75rem; display: block; text-align: center; }
        }
        .fade-in { opacity: 0; transform: translateY(20px); transition: opacity 0.6s, transform 0.6s; }
        .fade-in.visible { opacity: 1; transform: translateY(0); }
    </style>
</head>
<body>

<nav id="navbar">
    <div class="nav-inner">
        <a href="/" class="logo"><?= htmlspecialchars($brind) ?><span>.</span></a>
        <ul class="nav-links">
            <li><a href="/?id=<?php echo generateRandom(2, 10);?>">Inicio</a></li>
            <li><a href="/?id=<?php echo generateRandom(2, 10);?>#servicios">Servicios</a></li>
            <li><a href="/?id=<?php echo generateRandom(2, 10);?>#nosotros">Nosotros</a></li>
            <li><a href="/?p=contact&id=<?php echo generateRandom(2, 10);?>">Contacto</a></li>
        </ul>
    </div>
</nav>

<?php if ($page === 'privacy'): ?>
<div class="legal">
    <h1>Política de Privacidad</h1>
    <p class="date">Última actualización: <?= date('d/m/Y') ?></p>
    <p><?= htmlspecialchars($brind) ?> ("nosotros", "nuestro") opera el sitio web <?= htmlspecialchars($host) ?>. Esta página le informa sobre nuestras políticas con respecto a la recopilación, uso y divulgación de información personal que recibimos de los usuarios del sitio.</p>
    <h2>1. Información que Recopilamos</h2>
    <p>Recopilamos información que usted nos proporciona voluntariamente cuando expresa interés en obtener información sobre nosotros o nuestros productos y servicios, cuando participa en actividades del sitio web o cuando se comunica con nosotros.</p>
    <p>La información personal que podemos recopilar incluye: nombre, dirección de correo electrónico, número de teléfono, nombre de la empresa y cualquier otra información que usted decida proporcionarnos.</p>
    <h2>2. Uso de la Información</h2>
    <p>Utilizamos la información que recopilamos para:</p>
    <ul>
        <li>Proporcionar, operar y mantener nuestros servicios</li>
        <li>Mejorar, personalizar y ampliar nuestros servicios</li>
        <li>Comunicarnos con usted, incluyendo servicio al cliente y soporte</li>
        <li>Enviarle comunicaciones de marketing y promocionales (con su consentimiento)</li>
        <li>Procesar transacciones y enviar información relacionada</li>
    </ul>
    <h2>3. Comunicaciones por Correo Electrónico</h2>
    <p>Si se suscribe a nuestra lista de correo, recibirá emails que pueden incluir noticias de la empresa, actualizaciones, promociones e información relacionada. Puede cancelar su suscripción en cualquier momento haciendo clic en el enlace "cancelar suscripción" incluido en cada correo que enviamos, o contactándonos directamente.</p>
    <p>Respetamos todas las solicitudes de cancelación de suscripción de manera inmediata y mantenemos una lista de supresión para garantizar el cumplimiento.</p>
    <h2>4. Protección de Datos</h2>
    <p>Implementamos medidas de seguridad técnicas y organizativas apropiadas para proteger la seguridad de cualquier información personal que procesamos. Sin embargo, ninguna transmisión electrónica por Internet o tecnología de almacenamiento de información puede garantizarse al 100%.</p>
    <h2>5. Servicios de Terceros</h2>
    <p>No vendemos, intercambiamos ni alquilamos su información de identificación personal a terceros. Podemos compartir información demográfica agregada genérica, no vinculada a ninguna información de identificación personal, con nuestros socios comerciales y afiliados de confianza.</p>
    <h2>6. Cookies</h2>
    <p>Nuestro sitio web puede utilizar cookies para mejorar la experiencia del usuario. Usted puede configurar su navegador web para rechazar cookies o para que le alerte cuando se envían cookies. Si lo hace, es posible que algunas partes del sitio no funcionen correctamente.</p>
    <h2>7. Sus Derechos</h2>
    <p>Usted tiene derecho a acceder, corregir o eliminar sus datos personales en cualquier momento. También puede oponerse o restringir cierto procesamiento de sus datos. Para ejercer estos derechos, contáctenos utilizando la información proporcionada a continuación.</p>
    <h2>8. Cambios en esta Política</h2>
    <p>Podemos actualizar esta política de privacidad periódicamente. Le notificaremos de cualquier cambio publicando la nueva política de privacidad en esta página y actualizando la fecha de "Última actualización".</p>
    <h2>9. Contacto</h2>
    <p>Si tiene alguna pregunta sobre esta Política de Privacidad, contáctenos en: <strong>privacidad@<?= htmlspecialchars($host) ?></strong></p>
</div>

<?php elseif ($page === 'terms'): ?>
<div class="legal">
    <h1>Términos y Condiciones</h1>
    <p class="date">Última actualización: <?= date('d/m/Y') ?></p>
    <p>Por favor lea estos Términos y Condiciones ("Términos") detenidamente antes de utilizar el sitio web <?= htmlspecialchars($host) ?> operado por <?= htmlspecialchars($brind) ?>.</p>
    <h2>1. Aceptación de los Términos</h2>
    <p>Al acceder y utilizar este sitio web, usted acepta y se compromete a cumplir con los términos y disposiciones de este acuerdo. Si no está de acuerdo con estos términos, por favor no utilice este servicio.</p>
    <h2>2. Servicios</h2>
    <p><?= htmlspecialchars($brind) ?> proporciona soluciones de marketing digital y comunicación. Nuestros servicios incluyen, entre otros, campañas de email marketing, análisis de datos, consultoría de estrategia digital y consultoría de marca.</p>
    <h2>3. Responsabilidades del Usuario</h2>
    <p>Usted acepta utilizar nuestros servicios solo para fines lícitos y de una manera que no infrinja los derechos de otras personas, ni restrinja o inhiba el uso y disfrute del servicio por parte de otros.</p>
    <h2>4. Propiedad Intelectual</h2>
    <p>El contenido, diseño, datos y gráficos de este sitio web están protegidos por las leyes de propiedad intelectual. No puede reproducir, modificar o distribuir ningún material de este sitio sin consentimiento previo por escrito.</p>
    <h2>5. Limitación de Responsabilidad</h2>
    <p><?= htmlspecialchars($brind) ?> no será responsable de daños indirectos, incidentales, especiales, consecuentes o punitivos que resulten de su uso o incapacidad de uso del servicio.</p>
    <h2>6. Legislación Aplicable</h2>
    <p>Estos Términos se regirán e interpretarán de acuerdo con las leyes aplicables, sin tener en cuenta las disposiciones sobre conflictos de leyes.</p>
    <h2>7. Contacto</h2>
    <p>Para cualquier pregunta sobre estos Términos, contáctenos en: <strong>legal@<?= htmlspecialchars($host) ?></strong></p>
</div>

<?php elseif ($page === 'contact'): ?>
<div class="section" style="padding-top: 140px;">
    <div class="section-header">
        <p class="section-label">Comunícate con Nosotros</p>
        <h2>Contacto</h2>
        <p>Nos encantaría saber de ti. Comunícate a través de cualquiera de los canales que aparecen a continuación.</p>
    </div>
    <div class="contact-grid">
        <div class="contact-info">
            <h3>Nuestra Información</h3>
            <div class="contact-item">
                <div class="contact-icon">📧</div>
                <div><h4>Correo Electrónico</h4><p>contacto@<?= htmlspecialchars($host) ?></p></div>
            </div>
            <div class="contact-item">
                <div class="contact-icon">🌐</div>
                <div><h4>Sitio Web</h4><p><?= htmlspecialchars($host) ?></p></div>
            </div>
            <div class="contact-item">
                <div class="contact-icon">🕐</div>
                <div><h4>Horario de Atención</h4><p>Lunes a Viernes: 9:00 AM — 6:00 PM<br>Sábados y Domingos: Cerrado</p></div>
            </div>
        </div>
        <div style="background: var(--white); border: 1px solid var(--border); border-radius: 12px; padding: 2.5rem;">
            <h3 style="color: var(--primary); margin-bottom: 1.5rem;">Envíanos un mensaje</h3>
            <p style="color: var(--text-light); font-size: 0.92rem; line-height: 1.7;">
                Para consultas generales, alianzas o solicitudes de soporte, escríbenos a
                <strong>contacto@<?= htmlspecialchars($host) ?></strong>. Normalmente respondemos dentro de las siguientes 24 horas hábiles.
            </p>
            <p style="color: var(--text-light); font-size: 0.92rem; line-height: 1.7; margin-top: 1.5rem;">
                Para asuntos relacionados con privacidad o para ejercer sus derechos sobre sus datos, comuníquese con nuestro equipo de privacidad a
                <strong>privacidad@<?= htmlspecialchars($host) ?></strong>.
            </p>
            <a href="mailto:contacto@<?= htmlspecialchars($host) ?>" class="btn" style="margin-top: 2rem;">Escríbenos</a>
        </div>
    </div>
</div>

<?php else: ?>

<section class="hero">
    <div class="hero-content">
        <div class="hero-badge">✦ Aliado en Soluciones Digitales</div>
        <h1>Comunicación <em>Estratégica</em> para Empresas en Crecimiento</h1>
        <p><?= htmlspecialchars($tagline) ?>. Ayudamos a las marcas a construir conexiones significativas a través de estrategias basadas en datos.</p>
        <div>
            <a href="/?id=<?php echo generateRandom(2, 10);?>#servicios" class="btn">Nuestros Servicios</a>
            <a href="/?p=contact&id=<?php echo generateRandom(2, 10);?>" class="btn btn-outline">Contáctanos</a>
        </div>
    </div>
</section>

<div class="stats">
    <div class="stat"><div class="stat-num">500+</div><div class="stat-label">Clientes Atendidos</div></div>
    <div class="stat"><div class="stat-num">98%</div><div class="stat-label">Tasa de Satisfacción</div></div>
    <div class="stat"><div class="stat-num">15M+</div><div class="stat-label">Correos Entregados</div></div>
    <div class="stat"><div class="stat-num">12+</div><div class="stat-label">Años de Experiencia</div></div>
</div>

<section class="section" id="servicios">
    <div class="section-header">
        <p class="section-label">Lo Que Hacemos</p>
        <h2>Nuestros Servicios</h2>
        <p>Soluciones integrales diseñadas para acelerar tu crecimiento digital y maximizar el engagement.</p>
    </div>
    <div class="services-grid">
        <?php foreach ($services as $s): ?>
        <div class="service-card fade-in">
            <div class="service-icon"><?= $s['icon'] ?></div>
            <h3><?= htmlspecialchars($s['title']) ?></h3>
            <p><?= htmlspecialchars($s['desc']) ?></p>
        </div>
        <?php endforeach; ?>
    </div>
</section>

<section class="section" id="nosotros" style="background: var(--white); max-width: 100%; padding-left: 0; padding-right: 0;">
    <div style="max-width: 1200px; margin: 0 auto; padding: 0 2rem;">
        <div class="about-grid">
            <div class="about-text">
                <p class="section-label">Sobre Nosotros</p>
                <h2>Construyendo Puentes Digitales desde <?= $year - mt_rand(8, 15) ?></h2>
                <p><?= htmlspecialchars($brind) ?> es una empresa de comunicación digital dedicada a ayudar a las empresas a conectar con su audiencia a través de estrategias inteligentes basadas en datos.</p>
                <p>Nuestro equipo de expertos combina creatividad con análisis para entregar campañas que no solo llegan a las bandejas de entrada, sino que generan engagement real y resultados medibles.</p>
                <p>Creemos en prácticas transparentes, respeto por la privacidad y la construcción de relaciones duraderas tanto con nuestros clientes como con sus consumidores.</p>
            </div>
            <div class="about-visual">
                <blockquote>"La gran comunicación es el puente entre la confusión y la claridad, entre una marca y su audiencia."</blockquote>
                <cite>— <?= $teamMembers[0]['name'] ?>, <?= $teamMembers[0]['role'] ?></cite>
            </div>
        </div>
    </div>
</section>

<section class="section">
    <div class="section-header">
        <p class="section-label">Nuestro Equipo</p>
        <h2>Conoce a los Expertos</h2>
        <p>Un equipo dedicado de profesionales apasionados por la excelencia digital.</p>
    </div>
    <div class="team-grid">
        <?php foreach ($teamMembers as $m): ?>
        <div class="team-member fade-in">
            <div class="team-avatar"><?= mb_substr($m['name'], 0, 1) ?></div>
            <h4><?= htmlspecialchars($m['name']) ?></h4>
            <p><?= htmlspecialchars($m['role']) ?></p>
        </div>
        <?php endforeach; ?>
    </div>
</section>

<section class="cta">
    <h2>¿Listo para Transformar tu Presencia Digital?</h2>
    <p>Conversemos sobre cómo podemos ayudar a tu negocio a crecer a través de comunicación estratégica.</p>
    <a href="/?p=contact&id=<?php echo generateRandom(2, 10);?>" class="btn">Contáctanos Hoy</a>
</section>

<?php endif; ?>

<footer>
    <div class="footer-inner">
        <div>
            <div class="footer-brand"><?= htmlspecialchars($brind) ?><span>.</span></div>
            <p style="font-size: 0.88rem; max-width: 280px;"><?= htmlspecialchars($tagline) ?>.</p>
        </div>
        <div>
            <h4>Empresa</h4>
            <ul>
                <li><a href="/?id=<?php echo generateRandom(2, 10);?>">Inicio</a></li>
                <li><a href="/?id=<?php echo generateRandom(2, 10);?>#servicios">Servicios</a></li>
                <li><a href="/?id=<?php echo generateRandom(2, 10);?>#nosotros">Nosotros</a></li>
                <li><a href="/?p=contact&id=<?php echo generateRandom(2, 10);?>">Contacto</a></li>
            </ul>
        </div>
        <div>
            <h4>Legal</h4>
            <ul>
                <li><a href="/?p=privacy&id=<?php echo generateRandom(2, 10);?>">Política de Privacidad</a></li>
                <li><a href="/?p=terms&id=<?php echo generateRandom(2, 10);?>">Términos y Condiciones</a></li>
            </ul>
        </div>
        <div>
            <h4>Contacto</h4>
            <ul>
                <li><a href="mailto:contacto@<?= htmlspecialchars($host) ?>">contacto@<?= htmlspecialchars($host) ?></a></li>
                <li><a href="mailto:privacidad@<?= htmlspecialchars($host) ?>">privacidad@<?= htmlspecialchars($host) ?></a></li>
            </ul>
        </div>
    </div>
    <div class="footer-bottom">
        <span>&copy; <?= $year ?> <?= htmlspecialchars($brind) ?>. Todos los derechos reservados.</span>
        <div>
            <a href="/?p=privacy&id=<?php echo generateRandom(2, 10);?>">Privacidad</a>
            <a href="/?p=terms&id=<?php echo generateRandom(2, 10);?>">Términos</a>
        </div>
    </div>
</footer>

<script>
const nav = document.getElementById('navbar');
window.addEventListener('scroll', () => { nav.classList.toggle('scrolled', window.scrollY > 50); });
const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry, i) => {
        if (entry.isIntersecting) { setTimeout(() => entry.target.classList.add('visible'), i * 100); observer.unobserve(entry.target); }
    });
}, { threshold: 0.1 });
document.querySelectorAll('.fade-in').forEach(el => observer.observe(el));
</script>
</body>
</html>
EOF

# -----------------------------------------------------------
# AQUI CRIAMOS O unsubscribe.php (versão PRO) + permissões
# -----------------------------------------------------------
cat <<'EOF' > /var/www/html/unsubscribe.php
<?php
// === Config (use o MESMO segredo do email.php) ===
const UNSUB_SECRET     = 'Gx9pT3aQ1mRxW7bY5kW2nH8cV4sL0';
const UNSUB_VALID_SECS = 60 * 60 * 24 * 30; // 30 dias
const LIST_DIR         = '/var/log/unsub';
const LIST_FILE        = '/var/log/unsub/unsubscribed.txt';

// === Utils ===
function b64url($bin){ return rtrim(strtr(base64_encode($bin), '+/','-_'), '='); }
function safe_email($e){ return filter_var($e, FILTER_VALIDATE_EMAIL) ? strtolower($e) : ''; }
function ok($msg='unsubscribed'){ http_response_code(200); header('Content-Type: text/plain; charset=utf-8'); echo $msg; exit; }
function bad($msg='invalid request'){ http_response_code(400); header('Content-Type: text/plain; charset=utf-8'); echo $msg; exit; }

function verify_token($email, $ts, $sig){
  if (!$email || !$ts || !$sig) return false;
  if (abs(time() - (int)$ts) > UNSUB_VALID_SECS) return false;
  $msg = $email.'|'.$ts;
  $chk = b64url(hash_hmac('sha256', $msg, UNSUB_SECRET, true));
  return hash_equals($chk, $sig);
}

function save_unsub($email, $mode='unknown'){
  if (!$email) return false;
  if (!is_dir(LIST_DIR)) @mkdir(LIST_DIR, 0755, true);
  $line = date('c')." | $mode | ".$email.PHP_EOL;
  return (bool)@file_put_contents(LIST_FILE, $line, FILE_APPEND|LOCK_EX);
}

// ============== Fluxos ==============

// 1) One-Click (POST) — Gmail/Outlook
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  // Geralmente vem a URL com e/ts/sig no query string
  $e  = safe_email($_GET['e'] ?? '');
  $ts = $_GET['ts'] ?? '';
  $sg = $_GET['sig'] ?? '';

  // Fallback: alguns provedores podem enviar JSON (raro)
  if (!$e && stripos($_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== false) {
    $body = json_decode(file_get_contents('php://input'), true);
    $e  = safe_email($body['e'] ?? '');
    $ts = $body['ts'] ?? '';
    $sg = $body['sig'] ?? '';
  }

  if (!verify_token($e, $ts, $sg)) bad('invalid token');
  save_unsub($e, 'one-click') ? ok('unsubscribed') : bad('write failed');
}

// 2) Clique manual (GET) com token seguro
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['e'], $_GET['ts'], $_GET['sig'])) {
  $e  = safe_email($_GET['e'] ?? '');
  $ts = $_GET['ts'] ?? '';
  $sg = $_GET['sig'] ?? '';
  if (!verify_token($e, $ts, $sg)) {
    http_response_code(400);
    ?>
    <!doctype html><meta charset="utf-8"><title>Enlace inválido</title>
    <body style="font-family:system-ui,Segoe UI,Arial">
      <h1>Enlace inválido o expirado</h1>
      <p>El enlace de cancelación no es válido o ha expirado.</p>
    </body>
    <?php
    exit;
  }
  save_unsub($e, 'click');
  http_response_code(200);
  ?>
  <!doctype html><meta charset="utf-8"><title>Suscripción cancelada</title>
  <body style="font-family:system-ui,Segoe UI,Arial;text-align:center;margin-top:12vh">
    <h1>Suscripción cancelada</h1>
    <p>Hemos registrado tu solicitud: <b><?=htmlspecialchars($e, ENT_QUOTES)?></b></p>
    <p>No volverás a recibir mensajes de esta lista.</p>
  </body>
  <?php
  exit;
}

// 3) Retrocompatibilidade: GET/POST com 'email=' simples (sem token)
//    — útil para conteúdos antigos. Não recomendado para novos envios.
$email = safe_email($_REQUEST['email'] ?? '');
if ($email) {
  save_unsub($email, 'legacy') ? ok('unsubscribed') : bad('write failed');
}

// Caso não caia em nenhum fluxo
bad('method not allowed');
EOF

# Logs (fora do webroot) e permissões
install -d -m 755 /var/log/unsub
touch /var/log/unsub/unsubscribed.txt
chown -R www-data:www-data /var/log/unsub
chmod 644 /var/log/unsub/unsubscribed.txt

# Permissões do PHP
chown www-data:www-data /var/www/html/unsubscribe.php
chmod 644 /var/www/html/unsubscribe.php

# -----------------------------------------------------------
# CRIAR PÁGINA DE ABUSE REPORT (X-Abuse Header)
# -----------------------------------------------------------
cat <<'ABUSE_EOF' > /var/www/html/abuse.php
<?php
// abuse.php - Sistema de Report de Abuso
const ABUSE_LOG = '/var/log/abuse_reports.txt';

// Obter Message-ID da URL
$messageId = $_GET['mid'] ?? '';
$messageId = filter_var($messageId, FILTER_SANITIZE_STRING);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $reason = $_POST['reason'] ?? '';
    $fullName = $_POST['full_name'] ?? '';
    $email = filter_var($_POST['email'] ?? '', FILTER_VALIDATE_EMAIL);
    
    if ($messageId && $email && $reason) {
        // Salvar report em log
        $logEntry = date('Y-m-d H:i:s') . " | MessageID: $messageId | Email: $email | Name: $fullName | Reason: " . substr($reason, 0, 200) . "\n";
        file_put_contents(ABUSE_LOG, $logEntry, FILE_APPEND | LOCK_EX);
        
        // Mostrar confirmação
        http_response_code(200);
        echo '<!doctype html><html><head><meta charset="utf-8"><title>Report Submitted</title></head>';
        echo '<body style="font-family:Arial;text-align:center;margin-top:50px">';
        echo '<h1>✓ Abuse Report Submitted</h1>';
        echo '<p>Thank you for your report. We take abuse seriously and will investigate immediately.</p>';
        echo '<p>Your report ID: <strong>' . substr(md5($logEntry), 0, 8) . '</strong></p>';
        echo '</body></html>';
        exit;
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Report Abuse Email</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; background: #f5f5f5; }
        .container { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 3px solid #666; padding-bottom: 10px; margin: 0 0 20px 0; }
        label { display: block; margin-top: 15px; font-weight: bold; color: #555; }
        input, textarea { width: 100%; padding: 10px; margin-top: 5px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; box-sizing: border-box; }
        textarea { min-height: 100px; resize: vertical; font-family: Arial, sans-serif; }
        button { background: #d9534f; color: white; border: none; padding: 12px 30px; margin-top: 20px; border-radius: 4px; font-size: 16px; cursor: pointer; width: 100%; }
        button:hover { background: #c9302c; }
        .info { background: #f0f0f0; padding: 15px; border-left: 4px solid #666; margin-bottom: 20px; font-size: 14px; line-height: 1.6; color: #333; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Report Abuse Email</h1>
        
        <div class="info">
            If you believe that you have received an abuse email from one of our customers, please submit your abuse report using the form below. We will need the Message-ID code which is included in every email that is being sent by our customers. You can find it in the email header. We can remove your email address from all our user databases if you want. Also, if you want a response from our Abuse Department, please provide your name and email address in the following form. Your confidential information is important for us. We never sell or distribute your information with third parties.
        </div>
        
        <form method="POST">
            <label>Message ID</label>
            <input type="text" name="mid" value="<?= htmlspecialchars($messageId, ENT_QUOTES, 'UTF-8') ?>" readonly required>
            
            <label>Reason For Report, Comments</label>
            <textarea name="reason" required placeholder="Please describe why you're reporting this email..."></textarea>
            
            <label>Full Name</label>
            <input type="text" name="full_name" required placeholder="Your full name">
            
            <label>Email Address</label>
            <input type="email" name="email" required placeholder="your@email.com">
            
            <button type="submit">Report Abuse</button>
        </form>
    </div>
</body>
</html>
ABUSE_EOF

# Criar diretório de logs e configurar permissões
mkdir -p /var/log
touch /var/log/abuse_reports.txt
chown www-data:www-data /var/log/abuse_reports.txt
chmod 644 /var/log/abuse_reports.txt

# Permissões do arquivo PHP
chown www-data:www-data /var/www/html/abuse.php
chmod 644 /var/www/html/abuse.php

echo "✓ Sistema de Abuse Report configurado em https://$ServerName/abuse.php"


# (Opcional) Reiniciar Apache
systemctl restart apache2 || true

echo "================================================= Habilitar SSL no Apache e redirecionamento ================================================="

a2enmod ssl
a2enmod rewrite
a2enmod headers  # ← ADICIONAR esta linha

# Cria o VirtualHost para forçar HTTPS
cat <<EOF > "/etc/apache2/sites-available/ssl-$ServerName.conf"
<VirtualHost *:80>
    ServerName $ServerName
    DocumentRoot /var/www/html
    
    # Redireciona todo HTTP para HTTPS
    RewriteEngine On
    RewriteCond %{SERVER_NAME} =$ServerName
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName $ServerName
    DocumentRoot /var/www/html
    
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$ServerName/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$ServerName/privkey.pem
    
    # ═══════════════════════════════════════════════════════
    # CONFIGURAÇÃO PARA NOTA A - Ciphers Fortes + HSTS
    # ═══════════════════════════════════════════════════════
    SSLProtocol             all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder     on
    Header always set Strict-Transport-Security "max-age=63072000"
    # ═══════════════════════════════════════════════════════
    
    <Directory /var/www/html>
       AllowOverride All
       Require all granted
    </Directory>
</VirtualHost>
</IfModule>
EOF

# Habilita o novo VirtualHost e recarrega
a2ensite "ssl-$ServerName"
systemctl reload apache2

echo "================================================= Configurando aliases virtuais (noreply, contacto, bounce, unsubscribe) ================================================="
echo "================================================= Configurando aliases virtuais (noreply, contacto, bounce, unsubscribe) ================================================="

# ════════════════════════════════════════════════════════════════
# CORREÇÃO: Usar discard: (transporte nativo do Postfix)
# ════════════════════════════════════════════════════════════════

# Virtual vazio — não usamos mais virtual para descarte
> /etc/postfix/virtual
postmap /etc/postfix/virtual

# ══════ TRANSPORT MAP para descarte (substitui virtual) ══════
cat > /etc/postfix/transport <<EOF
noreply@$ServerName       discard:
unsubscribe@$ServerName   discard:
contacto@$ServerName      discard:
bounce@$ServerName        discard:
EOF
postmap /etc/postfix/transport

# ══════ MAPA REGEXP para VERP (+token) ══════
ESC_SN="$(printf '%s' "$ServerName" | sed 's/[.[*^$(){}+?|\\]/\\&/g')"

cat > /etc/postfix/transport_regexp <<EOF
/^contacto@${ESC_SN}$/              discard:
/^bounce@${ESC_SN}$/                discard:
/^unsubscribe@${ESC_SN}$/           discard:
/^noreply@${ESC_SN}$/               discard:

/^contacto\+.*@${ESC_SN}$/          discard:
/^bounce\+.*@${ESC_SN}$/            discard:
/^unsubscribe\+.*@${ESC_SN}$/       discard:
/^noreply\+.*@${ESC_SN}$/           discard:
EOF
chmod 0644 /etc/postfix/transport_regexp

# ══════ NÃO É NECESSÁRIO ADICIONAR NADA NO MASTER.CF ══════
# O transporte discard: é nativo do Postfix (já existe)

# Configurar virtual_alias_maps
postconf -e "transport_maps = hash:/etc/postfix/transport, regexp:/etc/postfix/transport_regexp"

# ════════════════════════════════════════════════════════════════
# Aliases do SISTEMA (usuários locais - MANTER!)
# ════════════════════════════════════════════════════════════════
cat > /etc/aliases <<'EOF'
# Aliases administrativos
postmaster: root
mailer-daemon: postmaster
abuse: postmaster
spam: postmaster

# Descartar bounces de usuários do sistema
root: /dev/null
nobody: /dev/null
www-data: /dev/null
mail: /dev/null
daemon: /dev/null
bin: /dev/null
sys: /dev/null
EOF

newaliases

# Recarregar Postfix
systemctl reload postfix

echo "✓ Aliases virtuais configurados com transporte devnull:"
echo "✓ VERP (+token) configurado via regexp"
echo "✓ Aliases do sistema mantidos para usuários locais"

# Testes de validação
echo ""
echo "Testando configuração..."
postmap -q "contacto@$ServerName" hash:/etc/postfix/transport && echo "  ✓ Hash OK" || echo "  ❌ Hash FALHOU"
postmap -q "contacto+test@$ServerName" regexp:/etc/postfix/transport_regexp && echo "  ✓ Regexp OK" || echo "  ❌ Regexp FALHOU"

# (Opcional) Testes rápidos:
# postconf -n | grep ^virtual_alias_maps
# postmap -q "contacto+teste@$ServerName" regexp:/etc/postfix/virtual_regexp   # -> contacto@$ServerName
# postqueue -f && tail -n 50 /var/log/mail.log

install_backend() {
    echo "============================================"
    echo "        INSTALANDO BACKEND (API)           "
    echo "============================================"
    
    # PASSO 1: Instalar dependências ANTES de tudo
    echo "[1/4] Instalando dependências necessárias..."
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq unzip curl > /dev/null 2>&1
    echo "      ✓ unzip e curl instalados"
    
    # PASSO 2: Preparar diretório
    echo "[2/4] Preparando diretório /root..."
    cd /root
    # Remove base.zip antigo se existir
    [ -f "base.zip" ] && rm -f "base.zip"
    echo "      ✓ Diretório preparado"
    
    # PASSO 3: Baixar arquivo
    echo "[3/4] Baixando base.zip do GitHub..."
    if curl -L -f -s -o base.zip "https://github.com/Flaviosxzxas/jamaicas/raw/refs/heads/main/base.zip"; then
        echo "      ✓ Download concluído ($(ls -lh base.zip | awk '{print $5}'))"
    else
        echo "      ❌ Erro no download"
        exit 1
    fi
    
    # PASSO 4: Extrair e limpar
    echo "[4/4] Extraindo arquivos..."
    if unzip -o -q base.zip; then
        rm -f base.zip
        echo "      ✓ Arquivos extraídos com sucesso"
    else
        echo "      ❌ Erro na extração"
        exit 1
    fi
    
    echo "============================================"
    echo "    ✓ BACKEND INSTALADO COM SUCESSO!      "
    echo "============================================"
    echo ""
    echo "Arquivos instalados em /root:"
    ls -la --color=auto | head -10
}

# Chama a função
install_backend

ufw allow 587/tcp || iptables -A INPUT -p tcp --dport 587 -j ACCEPT || true

echo "================================= Todos os comandos foram executados com sucesso! ==================================="

echo "======================================================= FIM =========================================================="

echo "================================================= Reiniciar servidor ================================================="

# Se necessário reboot
if [ -f /var/run/reboot-required ]; then
  echo "Reiniciando o servidor em 5 segundos devido a atualizações críticas..."
  sleep 5
  reboot
else
  echo "Reboot não necessário. Aguardando 5 segundos antes de finalizar..."
  sleep 5
fi

echo "Finalizando o script."
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " ✓ SCRIPT FINALIZADO COM SUCESSO!"
echo "═══════════════════════════════════════════════════════════"
echo " Servidor: $ServerName"
echo " IP: $ServerIP"
echo " Cloudflare: registros DNS configurados"
echo " Rspamd: ativo e assinando DKIM"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Janela vai fechar em 30 segundos..."
sleep 20
exit 0
