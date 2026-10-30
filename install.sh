#!/usr/bin/env bash
#
# install.sh — Snapper + grub-btrfs para Fedora (solo root) + distrobox
# ---------------------------------------------------------------------
# Basado en sysguides-snapper-fedora (Madhu Desai / SysGuides), adaptado:
#   - Snapper SOLO para / (sin config de home; home se respalda con Borg)
#   - Limpieza por número + timeline diario corto (sin snapshots horarios)
#   - Instala distrobox + podman (contenedores rootless viven en ~, fuera
#     de los snapshots de root)
#   - Instala helpers sin depender de que se llamen snapper-*.sh
#   - Verifica al final que el plugin de DNF5 y los timers quedaron activos
#
# Requisitos:
#   - Layout de la guía de SysGuides (root en Btrfs, /boot dentro de root)
#   - Ejecutar desde la raíz del repo clonado (necesita config/ y scripts/)
#
# Uso:
#   ./install.sh            (como usuario normal, NO con sudo)

set -euo pipefail

# ---------------------------------------------------------------------------
# Ajustes (cambialos acá si querés otra política)
# ---------------------------------------------------------------------------

# Snapshots pre/post de DNF y manuales
NUMBER_LIMIT="2-10"
NUMBER_LIMIT_IMPORTANT="4-10"

# Timeline: un snapshot diario, se guardan los últimos 7.
# Cubre cambios hechos fuera de DNF (ediciones en /etc, etc.).
# Para desactivarlo del todo: TIMELINE_CREATE="no"
TIMELINE_CREATE="yes"
TIMELINE_LIMIT_HOURLY="0"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"

PACKAGES=(
    snapper
    libdnf5-plugin-actions
    btrfs-assistant
    inotify-tools
    make
    git
    distrobox
    podman
)

ACTIONS_DIR=/etc/dnf/libdnf5-plugins/actions.d
GRUB_BTRFS_REPO=https://github.com/Antynea/grub-btrfs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

STEP=0
step() { STEP=$((STEP + 1)); echo; echo "[$STEP] $*"; }
info() { echo "==> $*"; }
warn() { echo "⚠️  $*" >&2; }
die()  { echo "❌ Error: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

# ---------------------------------------------------------------------------
# Chequeos previos
# ---------------------------------------------------------------------------

step "Chequeos previos..."

[[ $EUID -ne 0 ]] || die "Ejecutalo como usuario normal: ./install.sh"

grep -q '^ID=fedora' /etc/os-release || die "Este script es para Fedora"

[[ "$(findmnt -n -o FSTYPE /)" == "btrfs" ]] || die "La raíz no es Btrfs"

compgen -G "$SCRIPT_DIR/scripts/*" >/dev/null \
    || die "No hay archivos en $SCRIPT_DIR/scripts/ (¿estás en la raíz del repo?)"

[[ -f "$SCRIPT_DIR/config/snapper.actions" ]] \
    || die "Falta $SCRIPT_DIR/config/snapper.actions"

# /boot separado = el rollback no incluye el kernel
if findmnt -n /boot >/dev/null 2>&1; then
    warn "/boot es una partición aparte: los snapshots NO van a incluir el kernel."
    warn "Para rollback completo, /boot tiene que estar dentro del subvolumen root (layout de la guía)."
    read -rp "¿Continuar igual? [s/N] " ans
    [[ "${ans,,}" == "s" ]] || exit 1
fi

# Avisar si el plugin de DNF o los helpers hacen algo con home
if grep -qn 'home' "$SCRIPT_DIR/config/snapper.actions" "$SCRIPT_DIR"/scripts/* 2>/dev/null; then
    warn "config/snapper.actions o scripts/ mencionan 'home':"
    grep -n 'home' "$SCRIPT_DIR/config/snapper.actions" "$SCRIPT_DIR"/scripts/* || true
    warn "Este setup no crea config de home, así que esas líneas van a fallar o sobran."
    read -rp "¿Continuar igual? (revisalo después) [s/N] " ans
    [[ "${ans,,}" == "s" ]] || exit 1
fi

# Pedir sudo una sola vez al principio
sudo -v

# ---------------------------------------------------------------------------
# Paquetes
# ---------------------------------------------------------------------------

step "Instalando paquetes..."
sudo dnf install -y "${PACKAGES[@]}"

# ---------------------------------------------------------------------------
# Snapper (solo root)
# ---------------------------------------------------------------------------

step "Configurando Snapper para / ..."

if ! sudo snapper -c root get-config &>/dev/null; then
    # Si /.snapshots quedó de una corrida anterior sin config, create-config
    # falla. Solo lo limpiamos si está vacío; si tiene algo, frenamos.
    if [[ -e /.snapshots ]]; then
        if [[ -n "$(sudo ls -A /.snapshots)" ]]; then
            die "/.snapshots existe y no está vacío, pero no hay config de root. Revisalo a mano."
        fi
        info "Eliminando /.snapshots vacío de una corrida anterior"
        if sudo btrfs subvolume show /.snapshots &>/dev/null; then
            sudo btrfs subvolume delete /.snapshots
        else
            sudo rmdir /.snapshots
        fi
    fi
    sudo snapper -c root create-config /
else
    info "La config de root ya existe, se actualiza"
fi

sudo restorecon -RF /.snapshots

sudo snapper -c root set-config \
    ALLOW_USERS="$REAL_USER" \
    SYNC_ACL=yes \
    NUMBER_CLEANUP=yes \
    NUMBER_LIMIT="$NUMBER_LIMIT" \
    NUMBER_LIMIT_IMPORTANT="$NUMBER_LIMIT_IMPORTANT" \
    EMPTY_PRE_POST_CLEANUP=yes \
    TIMELINE_CREATE="$TIMELINE_CREATE" \
    TIMELINE_CLEANUP=yes \
    TIMELINE_LIMIT_HOURLY="$TIMELINE_LIMIT_HOURLY" \
    TIMELINE_LIMIT_DAILY="$TIMELINE_LIMIT_DAILY" \
    TIMELINE_LIMIT_WEEKLY="$TIMELINE_LIMIT_WEEKLY" \
    TIMELINE_LIMIT_MONTHLY="$TIMELINE_LIMIT_MONTHLY" \
    TIMELINE_LIMIT_YEARLY="$TIMELINE_LIMIT_YEARLY"

if sudo snapper -c home get-config &>/dev/null; then
    warn "Existe una config 'home' de una instalación anterior. No la toco."
    warn "Para eliminarla (borra sus snapshots, no tus archivos): sudo snapper -c home delete-config"
fi

# ---------------------------------------------------------------------------
# updatedb
# ---------------------------------------------------------------------------

step "Excluyendo .snapshots de updatedb..."

UPDATEDB_CONF=/etc/updatedb.conf

if [[ -f "$UPDATEDB_CONF" ]] && grep -q '\.snapshots' "$UPDATEDB_CONF"; then
    info "Ya estaba excluido"
elif [[ -f "$UPDATEDB_CONF" ]] && grep -q '^PRUNENAMES' "$UPDATEDB_CONF"; then
    sudo sed -i 's|^\(PRUNENAMES\s*=\s*"\)|\1.snapshots |' "$UPDATEDB_CONF"
else
    echo 'PRUNENAMES = ".snapshots"' | sudo tee -a "$UPDATEDB_CONF" >/dev/null
fi

# ---------------------------------------------------------------------------
# grub-btrfs
# ---------------------------------------------------------------------------

step "Instalando grub-btrfs..."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

git clone --depth 1 "$GRUB_BTRFS_REPO" "$tmpdir/grub-btrfs"
info "grub-btrfs commit: $(git -C "$tmpdir/grub-btrfs" rev-parse --short HEAD)"

cfg="$tmpdir/grub-btrfs/config"
sed -i \
    -e 's|^#GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=.*|GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rd.live.overlay.overlayfs=1"|' \
    -e 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"|' \
    -e 's|^#GRUB_BTRFS_MKCONFIG=.*|GRUB_BTRFS_MKCONFIG=/usr/bin/grub2-mkconfig|' \
    -e 's|^#GRUB_BTRFS_SCRIPT_CHECK=.*|GRUB_BTRFS_SCRIPT_CHECK=grub2-script-check|' \
    "$cfg"

# Si upstream cambió el formato del config, el sed no hace nada en silencio
for key in GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS GRUB_BTRFS_GRUB_DIRNAME \
           GRUB_BTRFS_MKCONFIG GRUB_BTRFS_SCRIPT_CHECK; do
    grep -q "^${key}=" "$cfg" || die "No se pudo configurar $key en grub-btrfs (¿cambió el formato upstream?)"
done

(cd "$tmpdir/grub-btrfs" && sudo make install)
sudo systemctl enable --now grub-btrfsd.service

# ---------------------------------------------------------------------------
# Integración con DNF5
# ---------------------------------------------------------------------------

step "Instalando helpers e integración con DNF5..."

for f in "$SCRIPT_DIR"/scripts/*; do
    [[ -f "$f" ]] || continue
    sudo install -m 755 "$f" /usr/local/bin/
    sudo restorecon -v "/usr/local/bin/$(basename "$f")"
done

sudo mkdir -p "$ACTIONS_DIR"
sudo install -m 644 "$SCRIPT_DIR/config/snapper.actions" "$ACTIONS_DIR/"
sudo restorecon -v "$ACTIONS_DIR/snapper.actions"

# ---------------------------------------------------------------------------
# libvirt: NOCOW en el directorio de imágenes (solo si existe y está vacío)
# ---------------------------------------------------------------------------

LIBVIRT_IMAGES=/var/lib/libvirt/images
if [[ -d "$LIBVIRT_IMAGES" ]] && [[ -z "$(sudo ls -A "$LIBVIRT_IMAGES")" ]]; then
    step "Desactivando CoW en $LIBVIRT_IMAGES ..."
    sudo chattr +C "$LIBVIRT_IMAGES"
fi

# ---------------------------------------------------------------------------
# Timers y GRUB
# ---------------------------------------------------------------------------

step "Habilitando timers..."

sudo systemctl enable --now snapper-cleanup.timer
if [[ "$TIMELINE_CREATE" == "yes" ]]; then
    sudo systemctl enable --now snapper-timeline.timer
else
    sudo systemctl disable --now snapper-timeline.timer 2>/dev/null || true
fi

step "Regenerando configuración de GRUB..."
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# ---------------------------------------------------------------------------
# Verificación
# ---------------------------------------------------------------------------

step "Verificando..."

errors=0
check() {
    if eval "$2" &>/dev/null; then echo "  ✅ $1"; else echo "  ❌ $1"; errors=$((errors + 1)); fi
}

check "Config de snapper para root"     "sudo snapper -c root get-config"
check "snapper.actions instalado"       "[[ -f $ACTIONS_DIR/snapper.actions ]]"
check "grub-btrfsd activo"              "systemctl is-active grub-btrfsd.service"
check "snapper-cleanup.timer activo"    "systemctl is-active snapper-cleanup.timer"
if [[ "$TIMELINE_CREATE" == "yes" ]]; then
    check "snapper-timeline.timer activo" "systemctl is-active snapper-timeline.timer"
fi
check "distrobox instalado"             "command -v distrobox"

echo
if (( errors > 0 )); then
    die "$errors chequeo(s) fallaron. Revisá la salida de arriba."
fi

cat <<EOF
✅ Instalación completa.

Prueba recomendada (tienen que aparecer snapshots pre/post):
    sudo dnf install -y htop && snapper ls

Distrobox: los contenedores rootless viven en ~/.local/share/containers,
fuera de los snapshots de root. Excluilos del backup de Borg si pesan.
EOF