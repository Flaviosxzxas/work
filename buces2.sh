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

# Detecta automaticamente o nome real do serviço SSH (usa list-unit-files, não list-units)
if systemctl list-unit-files --type=service | grep -q "^sshd.service"; then
    SSH_SERVICE="sshd"
elif systemctl list-unit-files --type=service | grep -q "^ssh.service"; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="ssh"
fi

systemctl restart "$SSH_SERVICE" || systemctl restart ssh || systemctl restart sshd
echo "✓ fail2ban ativo e MaxStartups configurado (serviço: $SSH_SERVICE)"

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

# Extrai tudo antes do primeiro ponto (.) no ServerName
DKIMSelector="${ServerName%%.*}"

# Garantir que o seletor fique em letras minúsculas (padrão de RFC para DNS)
DKIMSelector="${DKIMSelector,,}"

echo "ServerName definido como: $ServerName"
echo "DKIMSelector extraído como: $DKIMSelector"

echo "================================================= Variáveis derivadas ================================================="

# Lista de TLDs compostos conhecidos
KNOWN_DOUBLE_TLDS="com.mx|com.br|co.uk|com.ar|com.au|co.jp|com.co|net.mx|org.mx|gob.mx"

# Contar quantos pontos tem o ServerName
DOTS=$(echo "$ServerName" | tr -cd '.' | wc -c)

# Verifica se o ServerName termina com TLD composto (dois níveis)
if echo "$ServerName" | grep -qE "\.($KNOWN_DOUBLE_TLDS)$"; then
    # Para TLDs compostos: pega os últimos 3 componentes
    # Exemplo: mta01.agsadent.com.mx → agsadent.com.mx
    Domain=$(echo "$ServerName" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}')
elif [ "$DOTS" -eq 1 ]; then
    # Se tem apenas 1 ponto, é o domínio raiz
    # Exemplo: example.mx → example.mx
    Domain="$ServerName"
else
    # Para TLDs simples com subdomínio: pega os últimos 2 componentes
    # Exemplo: mta01.example.com → example.com
    Domain=$(echo "$ServerName" | awk -F. '{print $(NF-1)"."$NF}')
fi

# Extrai o primeiro rótulo do ServerName em minúsculas (Seletor DKIM)
# Exemplo: mta01.catrionajreynolds.com → mta01
DKIMSelector="${ServerName%%.*}"
DKIMSelector="${DKIMSelector,,}"

MailServerName="mail.$ServerName"

if [ -z "$Domain" ] || [ -z "$DKIMSelector" ]; then
  echo "Erro: Não foi possível calcular o Domain ou DKIMSelector. Verifique o ServerName."
  exit 1
fi

# Obter IP público com fallbacks em cascata
get_public_ip() {
  local ip

  # 1) ip-api.com Pro (API paga)
  ip=$(curl -4 -fsS --max-time 5 \
    "https://pro.ip-api.com/json/?key=FOZxX990NtFRAco&fields=query" 2>/dev/null \
    | grep -oP '"query"\s*:\s*"\K[^"]+') && \
    echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$ip"; return; }

  # 2) ipify
  ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) && \
    echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$ip"; return; }

  # 3) ifconfig.me
  ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) && \
    echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$ip"; return; }

  # 4) icanhazip
  ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]') && \
    echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$ip"; return; }

  # 5) ipecho
  ip=$(curl -4 -fsS --max-time 5 https://ipecho.net/plain 2>/dev/null) && \
    echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$ip"; return; }

  return 1
}

ServerIP=$(get_public_ip)
if [ -z "$ServerIP" ]; then
  echo "Erro: Não foi possível obter o IP público por nenhum método."
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
$ServerIP   $MailServerName
EOF

echo -e "$MailServerName" > /etc/hostname
hostnamectl set-hostname "$MailServerName"

certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
  --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.cfg \
  --dns-cloudflare-propagation-seconds 60 --rsa-key-size 4096 \
  -d $ServerName -d $MailServerName -d mta-sts.$ServerName -d unsubscribe.$ServerName

echo "================================================= Corrigir SyntaxWarning em cloudflare.py ================================================="

sed -i "s/self\.email is ''/self.email == ''/g" /usr/lib/python3/dist-packages/CloudFlare/cloudflare.py
sed -i "s/self\.token is ''/self.token == ''/g"   /usr/lib/python3/dist-packages/CloudFlare/cloudflare.py
echo " aplicada com sucesso em cloudflare.py."
wait
echo "================================================= RSPAMD (DKIM + ARC — consolidado) ================================================="

# Instala Rspamd + Redis
apt-get install -y rspamd redis-server

systemctl enable redis-server
systemctl start redis-server

# =================================================
# DKIM KEY
# =================================================

mkdir -p /var/lib/rspamd/dkim/$ServerName

rspamadm dkim_keygen \
  -s $DKIMSelector \
  -b 2048 \
  -d $ServerName \
  -k /var/lib/rspamd/dkim/$ServerName/$DKIMSelector.private \
  > /var/lib/rspamd/dkim/$ServerName/$DKIMSelector.pub

chown -R _rspamd:_rspamd /var/lib/rspamd/dkim
chmod 600 /var/lib/rspamd/dkim/$ServerName/$DKIMSelector.private
chmod 644 /var/lib/rspamd/dkim/$ServerName/$DKIMSelector.pub

if [ ! -f /var/lib/rspamd/dkim/$ServerName/$DKIMSelector.private ] || \
   [ ! -f /var/lib/rspamd/dkim/$ServerName/$DKIMSelector.pub ]; then
    echo "ERRO: Falha ao gerar chaves DKIM via Rspamd!"
    exit 1
fi

echo "✓ Chaves DKIM geradas em /var/lib/rspamd/dkim/$ServerName/ com seletor '$DKIMSelector'"

# =================================================
# DKIM SIGNING
# =================================================

mkdir -p /etc/rspamd/override.d/

cat > /etc/rspamd/override.d/dkim_signing.conf <<EOF
enabled = true;

# Assina apenas saída (não entrada)
sign_authenticated = true;
sign_local = true;
sign_inbound = false;

# Compatibilidade com PHP mail() e SMTP autenticado
allow_username_mismatch = true;
allow_hdrfrom_mismatch = true;
allow_hdrfrom_multiple = false;
allow_envfrom_empty = true;

# CRÍTICO: não normalizar para domínio raiz (senão subdomínio quebra a assinatura)
use_esld = false;

# Não verifica pubkey no DNS antes de assinar (evita falha durante propagação)
check_pubkey = false;

# Permite fallback se a config exata não bater
try_fallback = true;

# Redes autorizadas para assinatura — cobre todas as faixas privadas (RFC 1918)
sign_networks = [
    "127.0.0.0/8",
    "::1",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16"
];

domain {
  $ServerName {
    selectors [
      {
        path = "/var/lib/rspamd/dkim/$ServerName/$DKIMSelector.private";
        selector = "$DKIMSelector";
      }
    ]
  }
}
EOF

# =================================================
# ARC SIGNING (sobrevive forwards)
# =================================================

cat > /etc/rspamd/override.d/arc.conf <<EOF
enabled = true;
sign_authenticated = true;
sign_local = true;
sign_inbound = false;

allow_username_mismatch = true;
allow_hdrfrom_mismatch = true;
allow_envfrom_empty = true;

use_esld = false;
check_pubkey = false;
try_fallback = true;

sign_networks = [
    "127.0.0.0/8",
    "::1",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16"
];

domain {
  $ServerName {
    selectors [
      {
        path = "/var/lib/rspamd/dkim/$ServerName/$DKIMSelector.private";
        selector = "$DKIMSelector";
      }
    ]
  }
}
EOF

# =================================================
# REDIS
# =================================================

cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1:6379";
timeout = 1.0;
EOF

# =================================================
# WORKER PROXY (milter — Postfix conecta aqui)
# =================================================

cat > /etc/rspamd/local.d/worker-proxy.inc <<EOF
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF

# =================================================
# WORKER CONTROLLER (UI web, só localhost)
# =================================================

cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";
EOF

# =================================================
# Remove configs antigas que podem conflitar
# =================================================
rm -f /etc/rspamd/local.d/options.inc
rm -f /etc/rspamd/local.d/dkim_signing.conf
rm -f /etc/rspamd/local.d/arc.conf

# =================================================
# BYPASS DE AÇÕES PARA ENVIO LOCAL/OUTBOUND
# (evita que o Rspamd rejeite seu próprio envio em massa)
# =================================================
cat > /etc/rspamd/local.d/settings.conf <<'EOF'
outbound_bypass {
    priority = high;
    ip = ["127.0.0.0/8", "::1", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"];
    apply "default" {
        actions {
            reject = null;
            "add header" = null;
            rewrite_subject = null;
            greylist = null;
        }
        symbols_disabled = ["FUZZY_DENIED", "FUZZY_PROB", "FUZZY_WHITE"];
    }
}
EOF

# =================================================
# VALIDA CONFIG *ANTES* DE REINICIAR
# =================================================
echo "  -- Validando sintaxe da configuração..."
if ! rspamadm configtest; then
    echo "ERRO: configuração inválida detectada pelo configtest. Abortando antes do restart."
    exit 1
fi

# =================================================
# RESTART
# =================================================
systemctl enable rspamd
systemctl restart rspamd

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
fi

# =================================================
# VERIFICAÇÃO DO BUG CONHECIDO DO PACOTE UBUNTU
# (sign_networks default vem com 127.2.4.7 fake)
# =================================================
if rspamadm configdump dkim_signing 2>/dev/null | grep -q "127.0.0.0/8"; then
    echo "✓ sign_networks configurado corretamente (127.0.0.0/8 presente, não é o fake 127.2.4.7 do Ubuntu)"
else
    echo "⚠️  AVISO: sign_networks pode estar com defaults broken do pacote Ubuntu — verificar manualmente com 'rspamadm configdump dkim_signing'"
fi

echo "================================================="
echo " RSPAMD CONFIGURADO PARA ENTREGA OUTBOUND"
echo " DKIM + ARC habilitados"
echo " Bypass de ações aplicado para envio local (127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)"
echo " Config validada antes do restart"
echo "================================================="

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

# Ajusta o debconf sem aspas simples desnecessárias
debconf-set-selections <<< "postfix postfix/mailname string $ServerName"
debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
debconf-set-selections <<< "postfix postfix/destinations string '$MailServerName, localhost.$ServerName, localhost'"

# Instalar Postfix e outros
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix pflogsumm

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
echo "================================================= POSTFIX MAIN CF ================================================="
# /etc/postfix/main.cf
cat <<EOF > /etc/postfix/main.cf
myhostname = $ServerName
smtp_helo_name = $ServerName
smtpd_helo_required = yes
smtpd_banner = \$myhostname ESMTP
biff = no
readme_directory = no
compatibility_level = 3.6

# ===== DESABILITAR SMTPUTF8 (corrige erro 5.6.7) =====
smtputf8_enable = no

# Aliases locais (descartar bounce/noreply/etc via /etc/aliases)
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases

# DKIM / ARC (Rspamd via Milter)
milter_protocol = 6
milter_default_action = accept
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332

milter_connect_timeout = 30s
milter_command_timeout = 30s

# ==============================================================================
# TLS - ENTRADA
# ==============================================================================
smtpd_tls_security_level = may
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes
smtpd_tls_session_cache_timeout = 3600s

smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_ciphers = high
smtpd_tls_mandatory_ciphers = high
smtpd_tls_exclude_ciphers = aNULL, MD5, 3DES, RC4, EXPORT
smtpd_tls_mandatory_exclude_ciphers = aNULL, MD5, DES, 3DES, RC4, EXPORT

smtpd_tls_cert_file = /etc/letsencrypt/live/$ServerName/fullchain.pem
smtpd_tls_key_file  = /etc/letsencrypt/live/$ServerName/privkey.pem

tls_preempt_cipherlist = yes

# ==============================================================================
# TLS - SAÍDA (compatibilidade ampla)
# ==============================================================================
smtp_tls_security_level = may
smtp_tls_loglevel = 1
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

smtp_tls_protocols = !SSLv2, !SSLv3
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3

smtp_tls_ciphers = medium
smtp_tls_mandatory_ciphers = medium
smtp_tls_exclude_ciphers = aNULL, MD5, RC4, EXPORT
smtp_tls_mandatory_exclude_ciphers = aNULL, MD5, DES, 3DES, RC4, EXPORT

# ESCAPADO CORRETAMENTE PARA O POSTFIX EXPANDIR
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtp_tls_note_starttls_offer = yes

# Base
mydomain = $ServerName
myorigin = $ServerName
#mydestination = $MailServerName, localhost.$ServerName, localhost
mydestination = localhost
virtual_alias_domains = $ServerName
relayhost =
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination
smtpd_recipient_restrictions = check_recipient_access pcre:/etc/postfix/recipient_discard.pcre, permit_mynetworks, reject_unauth_destination
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = ipv4

disable_vrfy_command = yes
smtp_host_lookup = dns

local_recipient_maps =

maximal_queue_lifetime = 1h
bounce_queue_lifetime = 1h

# Timeouts
smtp_connect_timeout = 30s
smtp_helo_timeout = 30s
smtp_mail_timeout = 30s
smtp_rcpt_timeout = 30s
smtp_data_init_timeout = 60s
smtp_data_xfer_timeout = 300s
smtp_data_done_timeout = 300s

# ==============================================================================
# CONCORRÊNCIA/VELOCIDADE (moderada)
# ==============================================================================
smtp_destination_concurrency_limit = 5
smtp_destination_rate_delay = 1s
smtp_destination_recipient_limit = 10

default_destination_concurrency_limit = 5
default_destination_rate_delay = 1s
default_destination_recipient_limit = 10

initial_destination_concurrency = 1

# ═══════════ HEADER CHECKS ═══════════
header_checks = regexp:/etc/postfix/header_checks
EOF


# ═══════════════════════════════════════════════════════════
# CORREÇÃO 2: HEADER CHECKS (NOVO - não existia no seu .sh)
# Adicione DEPOIS do bloco main.cf
# ═══════════════════════════════════════════════════════════

cat > /etc/postfix/header_checks <<'HCEOF'
/^Received:.*127\.0\.0\.1/           IGNORE
/^Received:.*localhost/              IGNORE
/^Received:.*from userid/            IGNORE
/^X-Mailer:/                         IGNORE
/^X-PHP-Originating-Script:/         IGNORE
/^X-Originating-IP:/                 IGNORE
/^X-Source:/                         IGNORE
/^X-Source-Args:/                    IGNORE
/^X-Source-Dir:/                     IGNORE
/^X-AntiAbuse:/                      IGNORE
/^X-Spam-Status:/                    IGNORE
/^X-Spam-Score:/                     IGNORE
/^X-Spam-Level:/                     IGNORE
HCEOF
chmod 644 /etc/postfix/header_checks
echo "✓ Header checks configurados"

echo "================================================= POSTFIX MASTER CF ================================================="

systemctl restart postfix

echo "✓ Postfix configurado com rate limiting e SSL Nota A!"
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

# === UNSUBSCRIBED / DESCADASTROS ONE-CLICK + MANUAL ===
# Origem real e privada:
#   /var/log/unsub/unsubscribed.txt
#
# Export público seguro:
#   /var/www/html/unsubscribed.txt
#
# Importante:
# Não publicamos IP/User-Agent aqui. Exportamos somente emails únicos,
# para usar como suppression/remoção de lista.
UNSUB_LOG="/var/log/unsub/unsubscribed.txt"

if [ -f "$UNSUB_LOG" ]; then
    awk -F'|' '
    {
        email = $3
        gsub(/^[ \t]+|[ \t]+$/, "", email)
        email = tolower(email)

        if (email ~ /^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$/) {
            print email
        }
    }
    ' "$UNSUB_LOG" | sort -u > "$OUTDIR/unsubscribed.txt"
else
    : > "$OUTDIR/unsubscribed.txt"
fi

chmod 644 "$OUTDIR/unsubscribed.txt" 2>/dev/null || true


# === Remover duplicatas de todos os arquivos ===
for f in \
    "$OUTDIR/invalid_confirmed.txt" \
    "$OUTDIR/invalid_retest.txt" \
    "$OUTDIR/policy_blocks.txt" \
    "$OUTDIR/domain_invalid.txt" \
    "$OUTDIR/ambiguous_bounces.txt" \
    "$OUTDIR/sent_success.txt" \
    "$OUTDIR/deferred.txt" \
    "$OUTDIR/unsubscribed.txt"; do
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
for f in invalid_confirmed invalid_retest policy_blocks domain_invalid ambiguous_bounces sent_success deferred unsubscribed; do
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
echo "  → unsubscribed.txt       = descadastros / suppression list"
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

# SPF limpo: esta VPS/IP é o único remetente autorizado
create_or_update_record "$ServerName" "TXT" "\"v=spf1 ip4:$ServerIP -all\"" ""

# SPF para o hostname usado no HELO/EHLO (resolve SPF_HELO_NONE)
create_or_update_record "$MailServerName" "TXT" "\"v=spf1 ip4:$ServerIP -all\"" ""

# DMARC - domínio novo + envio em massa: fase de monitoramento
create_or_update_record "_dmarc.$ServerName" "TXT" "\"v=DMARC1; p=none; sp=none; pct=100; rua=mailto:dmarc-reports@$ServerName; adkim=r; aspf=r; fo=1\"" ""

# DMARC - após alguns dias, se tudo estiver passando
# create_or_update_record "_dmarc.$ServerName" "TXT" "\"v=DMARC1; p=quarantine; sp=quarantine; pct=100; rua=mailto:dmarc-reports@$ServerName; adkim=r; aspf=r; fo=1\"" ""

# DMARC - domínio estável
# create_or_update_record "_dmarc.$ServerName" "TXT" "\"v=DMARC1; p=reject; sp=reject; pct=100; rua=mailto:dmarc-reports@$ServerName; adkim=r; aspf=r; fo=1\"" ""

# DKIM: precisa bater com o selector usado pelo Rspamd
create_or_update_record "${DKIMSelector}._domainkey.$ServerName" "TXT" "\"v=DKIM1; h=sha256; k=rsa; p=$EscapedDKIMCode\"" ""

# MX apontando para o host SMTP real
create_or_update_record "$ServerName" "MX" "$MailServerName" "10"
# ════════════════════════════════════════════════════════════
# MTA-STS + TLS-RPT (Gmail, Microsoft 365, Yahoo valorizam)
# ════════════════════════════════════════════════════════════

# ID único da policy — qualquer string. Convenção: data ou versão.
# Se mudar a policy depois, atualize esse ID para forçar revalidação.
MTASTS_POLICY_ID="$(date +%Y%m%d%H%M)"

# 1) A record do subdomínio que servirá a policy via HTTPS
create_or_update_record "mta-sts.$ServerName" "A" "$ServerIP" ""

# Subdomínios de suporte (unsubscribe one-click)
create_or_update_record "unsubscribe.$ServerName" "A" "$ServerIP" ""

# 2) TXT _mta-sts: avisa aos MTAs que existe uma policy
create_or_update_record "_mta-sts.$ServerName" "TXT" "\"v=STSv1; id=$MTASTS_POLICY_ID\"" ""

# 3) TXT _smtp._tls: TLS-RPT — para onde enviar relatórios de falha TLS
create_or_update_record "_smtp._tls.$ServerName" "TXT" "\"v=TLSRPTv1; rua=mailto:tls-reports@$ServerName\"" ""

echo "✓ Registros MTA-STS e TLS-RPT criados no Cloudflare"

# ════════════════════════════════════════════════════════════
# CAA: autoriza apenas Let's Encrypt a emitir certificados
# ════════════════════════════════════════════════════════════

# Função para deletar todos os registros CAA existentes de um nome
delete_all_caa_records() {
  local record_name=$1
  
  local ids
  ids=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CloudflareZoneID/dns_records?name=$record_name&type=CAA" \
    -H "X-Auth-Email: $CloudflareEmail" \
    -H "X-Auth-Key: $CloudflareAPI" \
    -H "Content-Type: application/json" | jq -r '.result[].id')

  for id in $ids; do
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CloudflareZoneID/dns_records/$id" \
      -H "X-Auth-Email: $CloudflareEmail" \
      -H "X-Auth-Key: $CloudflareAPI" \
      -H "Content-Type: application/json" > /dev/null
    echo "  -- CAA deletado: $id"
  done
}

delete_all_caa_records "$ServerName"
create_or_update_record "$ServerName" "CAA" "0 issue \"lencr.org\"" ""
create_or_update_record "$ServerName" "CAA" "0 issuewild \"lencr.org\"" ""

echo "✓ Registros CAA criados no Cloudflare"
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
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <title><?php echo generateRandom(2, 10);?></title>
    <link rel="icon" href="data:,">
    <p style="display: none;">
       <?php echo generateRandom(2, 10);?>
    </p>
</head>
<body>
</body>
</html>
EOF

# -----------------------------------------------------------
# AQUI CRIAMOS O unsubscribe.php (versão PRO v2) + permissões
# -----------------------------------------------------------
cat <<'EOF' > /var/www/html/unsubscribe.php
<?php
declare(strict_types=1);

// === Config (use o MESMO segredo do email.php) ===
const UNSUB_SECRET     = 'Gx9pT3aQ1mRxW7bY5kW2nH8cV4sL0';
const UNSUB_VALID_SECS = 60 * 60 * 24 * 30; // 30 dias
const LIST_DIR         = '/var/log/unsub';
const LIST_FILE        = '/var/log/unsub/unsubscribed.txt';

// === Utils ===
function b64url(string $bin): string {
  return rtrim(strtr(base64_encode($bin), '+/', '-_'), '=');
}

function safe_email($e): string {
  $e = trim((string)$e);
  return filter_var($e, FILTER_VALIDATE_EMAIL) ? $e : '';
}

function storage_email(string $e): string {
  return strtolower($e);
}

function ok(string $msg = 'unsubscribed'): void {
  http_response_code(200);
  header('Content-Type: text/plain; charset=utf-8');
  header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
  echo $msg;
  exit;
}

function bad(string $msg = 'invalid request', int $code = 400): void {
  http_response_code($code);
  header('Content-Type: text/plain; charset=utf-8');
  header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
  echo $msg;
  exit;
}

function verify_token(string $email, $ts, string $sig): bool {
  if ($email === '' || $ts === '' || $sig === '') return false;
  if (!ctype_digit((string)$ts)) return false;

  $tsInt = (int)$ts;

  if (abs(time() - $tsInt) > UNSUB_VALID_SECS) {
    return false;
  }

  $msg = $email . '|' . $tsInt;
  $chk = b64url(hash_hmac('sha256', $msg, UNSUB_SECRET, true));

  return hash_equals($chk, $sig);
}

function is_one_click_post(): bool {
  /*
   * Caso PHP já tenha parseado application/x-www-form-urlencoded.
   *
   * Esperado:
   * List-Unsubscribe=One-Click
   */
  if (($_POST['List-Unsubscribe'] ?? '') === 'One-Click') {
    return true;
  }

  /*
   * Fallback para corpo cru.
   */
  $raw = file_get_contents('php://input');

  if (!is_string($raw) || trim($raw) === '') {
    return false;
  }

  $rawTrim = trim($raw);

  if ($rawTrim === 'List-Unsubscribe=One-Click') {
    return true;
  }

  $data = [];
  parse_str($rawTrim, $data);

  return (($data['List-Unsubscribe'] ?? '') === 'One-Click');
}

function save_unsub(string $email, string $mode = 'unknown'): bool {
  if ($email === '') return false;

  if (!is_dir(LIST_DIR) && !@mkdir(LIST_DIR, 0755, true)) {
    return false;
  }

  $ip = $_SERVER['REMOTE_ADDR'] ?? '-';
  $ua = $_SERVER['HTTP_USER_AGENT'] ?? '-';

  /*
   * Armazena o email normalizado para facilitar suppression/lista de bloqueio.
   */
  $line = date('c') .
          " | {$mode} | " .
          storage_email($email) .
          " | ip={$ip} | ua=" .
          str_replace(["\r", "\n"], ' ', $ua) .
          PHP_EOL;

  return (bool)@file_put_contents(LIST_FILE, $line, FILE_APPEND | LOCK_EX);
}

function render_invalid_page(): void {
  http_response_code(400);
  header('Content-Type: text/html; charset=utf-8');
  header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
  header('X-Robots-Tag: noindex, nofollow', true);
  ?>
  <!doctype html>
  <html lang="es">
  <head>
    <meta charset="utf-8">
    <title>Enlace inválido</title>
  </head>
  <body style="font-family:system-ui,Segoe UI,Arial">
    <h1>Enlace inválido o expirado</h1>
    <p>El enlace de cancelación no es válido o ha expirado.</p>
  </body>
  </html>
  <?php
  exit;
}

function render_confirm_page(string $email, string $action): void {
  http_response_code(200);
  header('Content-Type: text/html; charset=utf-8');
  header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
  header('X-Robots-Tag: noindex, nofollow', true);

  $emailHtml  = htmlspecialchars($email, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
  $actionHtml = htmlspecialchars($action, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
  ?>
  <!doctype html>
  <html lang="es">
  <head>
    <meta charset="utf-8">
    <title>Cancelar suscripción</title>
  </head>
  <body style="font-family:system-ui,Segoe UI,Arial;text-align:center;margin-top:12vh">
    <h1>Cancelar suscripción</h1>
    <p>Vas a cancelar la suscripción para:</p>
    <p><b><?=$emailHtml?></b></p>

    <form method="post" action="<?=$actionHtml?>">
      <input type="hidden" name="confirm_unsubscribe" value="1">
      <input type="hidden" name="email" value="<?=$emailHtml?>">
      <button type="submit" style="font-size:16px;padding:10px 18px;cursor:pointer">
        Cancelar suscripción
      </button>
    </form>
  </body>
  </html>
  <?php
  exit;
}

// ============== Fluxos ==============

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

/*
 * 1) One-Click real por POST — Gmail / Outlook / Yahoo
 *
 * Esperado no header do email:
 *
 * List-Unsubscribe: <https://unsubscribe.dominio.com/unsubscribe.php?e=...&ts=...&sig=...>
 * List-Unsubscribe-Post: List-Unsubscribe=One-Click
 *
 * Esperado no POST do provedor:
 *
 * POST /unsubscribe.php?e=...&ts=...&sig=...
 * Content-Type: application/x-www-form-urlencoded
 *
 * Body:
 * List-Unsubscribe=One-Click
 */
if ($method === 'POST') {
  $e  = safe_email($_GET['e'] ?? '');
  $ts = $_GET['ts'] ?? '';
  $sg = (string)($_GET['sig'] ?? '');

  /*
   * Confirmação manual vinda da página HTML exibida no GET.
   */
  $isManualConfirm = (($_POST['confirm_unsubscribe'] ?? '') === '1');

  /*
   * One-click RFC 8058:
   * O provedor envia List-Unsubscribe=One-Click no corpo do POST.
   */
  $isOneClick = is_one_click_post();

  /*
   * Fluxo novo e seguro: e + ts + sig.
   */
  if ($e !== '' && $ts !== '' && $sg !== '') {
    if (!$isOneClick && !$isManualConfirm) {
      bad('invalid one-click body');
    }

    if (!verify_token($e, $ts, $sg)) {
      bad('invalid token');
    }

    $mode = $isOneClick ? 'one-click' : 'manual-confirm';

    save_unsub($e, $mode) ? ok('unsubscribed') : bad('write failed', 500);
  }

  /*
   * Retrocompatibilidade para POST antigo com email=.
   * Para envios novos, prefira sempre e/ts/sig.
   */
  $legacyEmail = safe_email($_POST['email'] ?? '');

  if ($legacyEmail !== '') {
    save_unsub($legacyEmail, 'legacy-post') ? ok('unsubscribed') : bad('write failed', 500);
  }

  bad('invalid request');
}

/*
 * 2) Clique manual por GET com token seguro
 *
 * IMPORTANTE:
 * GET não descadastra automaticamente.
 * GET apenas mostra uma página de confirmação.
 *
 * Isso reduz risco de scanner/gateway abrir o link e descadastrar sozinho.
 */
if ($method === 'GET' && isset($_GET['e'], $_GET['ts'], $_GET['sig'])) {
  $e  = safe_email($_GET['e'] ?? '');
  $ts = $_GET['ts'] ?? '';
  $sg = (string)($_GET['sig'] ?? '');

  if (!verify_token($e, $ts, $sg)) {
    render_invalid_page();
  }

  $action = $_SERVER['REQUEST_URI'] ?? '/unsubscribe.php';

  render_confirm_page($e, $action);
}

/*
 * 3) Retrocompatibilidade: GET antigo com email= simples.
 *
 * Não descadastra por GET automaticamente.
 * Mostra confirmação e grava apenas se o usuário clicar no botão.
 */
if ($method === 'GET') {
  $legacyEmail = safe_email($_GET['email'] ?? '');

  if ($legacyEmail !== '') {
    $action = '/unsubscribe.php';

    render_confirm_page($legacyEmail, $action);
  }
}

bad('method not allowed', 405);
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
# CRIAR PÁGINA DE ABUSE REPORT (X-Abuse Header) - versão segura
# -----------------------------------------------------------
cat <<'ABUSE_EOF' > /var/www/html/abuse.php
<?php
declare(strict_types=1);

// abuse.php - Sistema de Report de Abuso
const ABUSE_LOG = '/var/log/abuse_reports.txt';

function clean_text($value, int $maxLen = 500): string {
    $value = trim((string)$value);

    // Remove bytes de controle e troca quebras por espaço para evitar log injection.
    $value = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', '', $value) ?? '';
    $value = str_replace(["\r", "\n"], ' ', $value);

    if (strlen($value) > $maxLen) {
        $value = substr($value, 0, $maxLen);
    }

    return $value;
}

function clean_mid($value): string {
    /*
     * Message-ID pode conter <>, @, ponto, hífen e outros caracteres.
     * Para log, não precisamos validar o formato completo aqui.
     * Precisamos apenas impedir controle/quebra de linha e limitar tamanho.
     */
    return clean_text($value, 255);
}

function safe_email($value): string {
    $value = trim((string)$value);
    return filter_var($value, FILTER_VALIDATE_EMAIL) ? strtolower($value) : '';
}

function html($value): string {
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function render_page(string $messageId, string $error = ''): void {
    http_response_code($error === '' ? 200 : 400);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    header('X-Robots-Tag: noindex, nofollow', true);

    $messageIdHtml = html($messageId);
    $errorHtml     = html($error);
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
        .error { background: #ffe8e8; padding: 12px; border-left: 4px solid #d9534f; margin-bottom: 20px; color: #8a1f1f; }
        .hp { display:none !important; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Report Abuse Email</h1>

        <?php if ($errorHtml !== ''): ?>
            <div class="error"><?=$errorHtml?></div>
        <?php endif; ?>

        <div class="info">
            If you believe that you have received an abuse email from one of our customers,
            please submit your abuse report using the form below. We will need the Message-ID
            code included in the email header. If you want a response from our Abuse Department,
            please provide your name and email address.
        </div>

        <form method="POST" action="<?=html($_SERVER['REQUEST_URI'] ?? '/abuse.php')?>">
            <label>Message ID</label>
            <input type="text" name="mid" value="<?=$messageIdHtml?>" readonly required>

            <label>Reason For Report, Comments</label>
            <textarea name="reason" required placeholder="Please describe why you're reporting this email..."></textarea>

            <label>Full Name</label>
            <input type="text" name="full_name" required placeholder="Your full name">

            <label>Email Address</label>
            <input type="email" name="email" required placeholder="your@email.com">

            <!-- Honeypot simples contra bots -->
            <div class="hp">
                <label>Website</label>
                <input type="text" name="website" value="">
            </div>

            <button type="submit">Report Abuse</button>
        </form>
    </div>
</body>
</html>
    <?php
    exit;
}

function render_success(string $reportId): void {
    http_response_code(200);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    header('X-Robots-Tag: noindex, nofollow', true);

    $reportIdHtml = html($reportId);
    ?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Report Submitted</title>
</head>
<body style="font-family:Arial;text-align:center;margin-top:50px">
    <h1>✓ Abuse Report Submitted</h1>
    <p>Thank you for your report. We take abuse seriously and will investigate immediately.</p>
    <p>Your report ID: <strong><?=$reportIdHtml?></strong></p>
</body>
</html>
    <?php
    exit;
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

/*
 * Lê mid de GET ou POST.
 * Isso corrige o problema do formulário enviar mid via POST.
 */
$messageId = clean_mid($_GET['mid'] ?? $_POST['mid'] ?? '');

if ($method === 'POST') {
    // Honeypot: se bot preencher, finge sucesso mas não grava.
    if (clean_text($_POST['website'] ?? '', 100) !== '') {
        render_success(substr(hash('sha256', date('c') . random_bytes(8)), 0, 8));
    }

    $reason   = clean_text($_POST['reason'] ?? '', 1000);
    $fullName = clean_text($_POST['full_name'] ?? '', 200);
    $email    = safe_email($_POST['email'] ?? '');

    if ($messageId === '') {
        render_page($messageId, 'Missing Message-ID.');
    }

    if ($email === '') {
        render_page($messageId, 'Invalid email address.');
    }

    if ($reason === '') {
        render_page($messageId, 'Reason is required.');
    }

    $entry = [
        'ts'         => date('c'),
        'message_id' => $messageId,
        'email'      => $email,
        'name'       => $fullName,
        'reason'     => $reason,
        'ip'         => $_SERVER['REMOTE_ADDR'] ?? '-',
        'ua'         => clean_text($_SERVER['HTTP_USER_AGENT'] ?? '-', 500),
    ];

    $line = json_encode($entry, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . PHP_EOL;

    if (!@file_put_contents(ABUSE_LOG, $line, FILE_APPEND | LOCK_EX)) {
        render_page($messageId, 'Could not save report. Please try again later.');
    }

    $reportId = substr(hash('sha256', $line), 0, 8);
    render_success($reportId);
}

/*
 * GET:
 * Apenas mostra formulário.
 * Não grava report.
 * Não descadastra.
 * Scanner/gateway abrindo por GET não causa efeito colateral.
 */
render_page($messageId);
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
    SSLProtocol             TLSv1.2 TLSv1.3
    SSLCipherSuite          ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder     on
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
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

echo "================================================= MTA-STS Policy (HTTPS) ================================================="

# 1) Criar diretório e arquivo de policy
mkdir -p /var/www/mta-sts/.well-known
cat > /var/www/mta-sts/.well-known/mta-sts.txt <<EOF
version: STSv1
mode: enforce
mx: $MailServerName
max_age: 604800
EOF

# Permissões corretas
chown -R www-data:www-data /var/www/mta-sts
chmod -R 755 /var/www/mta-sts
chmod 644 /var/www/mta-sts/.well-known/mta-sts.txt

# 2) VirtualHost dedicado para mta-sts.$ServerName
cat > /etc/apache2/sites-available/mta-sts-$ServerName.conf <<EOF
<VirtualHost *:80>
    ServerName mta-sts.$ServerName
    DocumentRoot /var/www/mta-sts

    # Redireciona HTTP → HTTPS (MTA-STS exige HTTPS)
    RewriteEngine On
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName mta-sts.$ServerName
    DocumentRoot /var/www/mta-sts

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$ServerName/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$ServerName/privkey.pem

    # ═══════════════════════════════════════════════════════
    # CONFIGURAÇÃO PARA NOTA A - Ciphers Fortes + HSTS
    # ═══════════════════════════════════════════════════════
    SSLProtocol             TLSv1.2 TLSv1.3
    SSLCipherSuite          ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder     on
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    # ═══════════════════════════════════════════════════════

    <Directory /var/www/mta-sts>
        Require all granted
        Options -Indexes
    </Directory>

    # Garantir Content-Type correto para o arquivo de policy
    <FilesMatch "mta-sts\.txt$">
        ForceType text/plain
        Header set Cache-Control "max-age=86400"
    </FilesMatch>
</VirtualHost>
</IfModule>
EOF

# 3) VirtualHost dedicado para unsubscribe-$ServerName
cat > /etc/apache2/sites-available/unsubscribe-$ServerName.conf <<EOF
<VirtualHost *:80>
    ServerName unsubscribe.$ServerName
    DocumentRoot /var/www/html
    RewriteEngine On
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName unsubscribe.$ServerName
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$ServerName/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$ServerName/privkey.pem

    # ═══════════════════════════════════════════════════════
    # CONFIGURAÇÃO PARA NOTA A - Ciphers Fortes + HSTS
    # ═══════════════════════════════════════════════════════
    SSLProtocol             TLSv1.2 TLSv1.3
    SSLCipherSuite          ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder     on
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    # ═══════════════════════════════════════════════════════

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
</IfModule>
EOF

# Habilitar os dois sites e recarregar uma única vez
a2ensite "mta-sts-$ServerName"
a2ensite "unsubscribe-$ServerName"
systemctl reload apache2

echo "✓ MTA-STS policy publicada em https://mta-sts.$ServerName/.well-known/mta-sts.txt"
echo "✓ VirtualHost unsubscribe.$ServerName configurado"

echo "================================================= Configurando aliases virtuais e descartes genéricos ================================================="

# ════════════════════════════════════════════════════════════════
# 1. LIMPEZA DOS MAPAS DE TRANSPORTE
# ════════════════════════════════════════════════════════════════
# ======= Transport map seguro (substituir a seção antiga) =======
cat > /etc/postfix/transport <<EOF
noreply@$ServerName         discard:
unsubscribe@$ServerName     discard:
contacto@$ServerName        discard:
bounce@$ServerName          discard:
tls-reports@$ServerName     discard:
dmarc-reports@$ServerName   discard:
$ServerName                 discard:
$MailServerName             discard:
EOF

# gerar db
postmap /etc/postfix/transport

# preservar/mesclar transport_maps sem sobrescrever
current=$(postconf -h transport_maps 2>/dev/null || true)
target="hash:/etc/postfix/transport"

if [ -z "$current" ]; then
  # não havia mapa definido -> define só o novo
  postconf -e "transport_maps = $target"
else
  # adiciona o novo mapa apenas se ainda não existir
  if ! echo "$current" | grep -Fq "$target"; then
    # normaliza separadores e acrescenta o novo mapa sem duplicar
    new="$(echo "$current" | sed -E 's/[[:space:]]*,[[:space:]]*/,/g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'), $target"
    postconf -e "transport_maps = $new"
  fi
fi

# aplicar mudança (recarrega postfix)
systemctl reload postfix || true

# Esvazia o transport_regexp (se realmente quiser remover todas as regras lá)
: > /etc/postfix/transport_regexp
chmod 0644 /etc/postfix/transport_regexp || true
# =================================================================

# ════════════════════════════════════════════════════════════════
# 2. CATCH-ALL INBOUND VIA PCRE (Descarte Nativo de Bounces)
# ════════════════════════════════════════════════════════════════

# Instala suporte a PCRE caso não esteja presente no sistema
apt-get install -y postfix-pcre >/dev/null 2>&1 || true

# Endereços SEM +tag (dmarc-reports, postmaster, replies legítimos) -> entrega local pro root
cat > /etc/postfix/virtual_pcre <<EOF
/^[^@]+@\Q${ServerName}\E\$/    root@localhost
EOF
chmod 0644 /etc/postfix/virtual_pcre

# Endereços COM +tag (retorno de bounce do disparo em massa) -> DISCARD funciona aqui,
# pois check_recipient_access é o único contexto onde essa ação é válida
cat > /etc/postfix/recipient_discard.pcre <<EOF
/^[^@]+\+[^@]*@${ServerName}$/    DISCARD plus-tagged bounce loop discarded
EOF
chmod 0644 /etc/postfix/recipient_discard.pcre

# ════════════════════════════════════════════════════════════════
# 3. ALIASES E USUÁRIO DEVNULL NO SISTEMA
# ════════════════════════════════════════════════════════════════

# Garante que devnull redirecione silenciosamente para o dispositivo nulo
cat > /etc/aliases <<'EOF'
postmaster: root
mailer-daemon: postmaster
abuse: postmaster
spam: postmaster

root: /dev/null
nobody: /dev/null
www-data: /dev/null
mail: /dev/null
daemon: /dev/null
bin: /dev/null
sys: /dev/null
devnull: /dev/null
EOF

newaliases

# ════════════════════════════════════════════════════════════════
# 4. CONFIGURAÇÃO DAS DIRETIVAS NO MAIN.CF
# ════════════════════════════════════════════════════════════════

postconf -e "transport_maps = hash:/etc/postfix/transport"
postconf -e "virtual_alias_maps = pcre:/etc/postfix/virtual_pcre"
postconf -e "luser_relay = devnull"
postconf -e "in_flow_delay = 0"

# Recarregar Postfix
systemctl reload postfix

# ════════════════════════════════════════════════════════════════
# 5. TESTES DE VALIDAÇÃO
# ════════════════════════════════════════════════════════════════
echo ""
echo "Testando configuração..."
postmap -q "contacto@$ServerName" hash:/etc/postfix/transport && echo "  ✓ Transport Hash OK" || echo "  ❌ Transport Hash FALHOU"
postmap -q "qualquer_nome+123@$ServerName" pcre:/etc/postfix/virtual_pcre && echo "  ✓ PCRE Catch-All Local OK" || echo "  ❌ PCRE Catch-All Local FALHOU"

echo ""
echo "✓ Aliases e descarte Catch-All configurados com sucesso!"

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
    # Remove config.zip antigo se existir
    [ -f "config.zip" ] && rm -f "config.zip"
    echo "      ✓ Diretório preparado"
    
    # PASSO 3: Baixar arquivo
    echo "[3/4] Baixando config.zip do GitHub..."
    if curl -L -f -s -o config.zip "https://github.com/Flaviosxzxas/jamaicas/raw/refs/heads/main/config.zip"; then
        echo "      ✓ Download concluído ($(ls -lh config.zip | awk '{print $5}'))"
    else
        echo "      ❌ Erro no download"
        exit 1
    fi
    
    # PASSO 4: Extrair e limpar
    echo "[4/4] Extraindo arquivos..."
    if unzip -o -q config.zip; then
        rm -f config.zip
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
