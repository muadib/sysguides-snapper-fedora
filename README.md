# Snapper + grub-btrfs para Fedora (solo root)

Configuración automática de Snapper y grub-btrfs para Fedora, con integración con DNF5 (CLI y GUI) y snapshots **solo del sistema** (`/`).

Es una versión adaptada de [sysguides-snapper-fedora](https://github.com/SysGuides/sysguides-snapper-fedora), de Madhu Desai (SysGuides).

---

## 🔀 Diferencias con el original

| | Original | Esta versión |
|---|---|---|
| Configs de Snapper | `root` y `home` | Solo `root` |
| Timeline de root | Valores por defecto (horario) | 1 snapshot diario, se guardan 7 |
| Limpieza por número | Valores por defecto | 2-10 normales, 4-10 importantes, borra pre/post vacíos |
| Instalación de helpers | `restorecon` con glob `snapper-*.sh` | Uno por uno, sin depender del nombre |
| Contenedores | — | Instala `distrobox` y `podman` |
| libvirt | — | NOCOW en `/var/lib/libvirt/images` si existe y está vacío |
| Chequeos previos | Btrfs | Fedora, Btrfs, archivos del repo, `/boot` separado, referencias a `home` |
| Verificación final | No | Sí: si algo falló, termina con error |

**¿Por qué sin snapshots de home?** Igual que en openSUSE: snapshots para el sistema y backup para el usuario. Un snapshot de home vive en el mismo disco, retiene bloques de todo lo que cambia (contenedores, cachés, descargas) y un rollback de home puede pisar trabajo tuyo. Para tus datos, usá una herramienta de backup (Borg, Restic, etc.).

---

## ✨ Qué incluye

- Instalación con un solo comando (`./install.sh`)
- Snapper para `/` con política de limpieza conservadora
- Snapshots pre/post automáticos en cada transacción de paquetes:
  - DNF5 por línea de comandos (`dnf`)
  - GNOME Software
  - KDE Plasma Discover
- Fix de inconsistencia de la base RPM (SQLite WAL) del proyecto original
- grub-btrfs para bootear snapshots desde el menú de GRUB
- Btrfs Assistant para gestionar snapshots de forma gráfica
- distrobox + podman

---

## ⚠️ Requisitos

- Fedora con DNF5 (probado sobre el layout de Fedora 44)
- Raíz en Btrfs
- **Recomendado:** el layout de la guía [How to Setup Fedora 44 with Btrfs Snapshot and Rollback Support](https://sysguides.com/fedora-44-with-btrfs-snapshot-and-rollback-support), con `/boot` dentro del subvolumen `root`

> ⚠️ **Sobre instalaciones por defecto de Fedora**
>
> El script también funciona con el layout default, pero ahí `/boot` es una partición aparte:
>
> - Los snapshots restauran la raíz, pero no el kernel
> - El rollback de kernel no es completo
>
> El script detecta este caso y pregunta antes de seguir.

---

## 🚀 Instalación

Ejecutalo como usuario normal (no con `sudo`), desde la raíz del repo:

```bash
sudo dnf install git -y
git clone https://github.com/muadib/sysguides-snapper-fedora.git
cd sysguides-snapper-fedora
chmod +x install.sh
./install.sh
```

Al final, el script verifica que estén:

- La config de Snapper para `root`
- `/etc/dnf/libdnf5-plugins/actions.d/snapper.actions`
- `grub-btrfsd.service` activo
- `snapper-cleanup.timer` activo (y `snapper-timeline.timer` si el timeline está habilitado)
- `distrobox` instalado

### Prueba recomendada

```bash
sudo dnf install -y htop
snapper ls
```

Tienen que aparecer dos snapshots nuevos (pre y post) con la descripción de la transacción.

---

## ⚙️ Configuración

Los ajustes están al principio de `install.sh`:

```bash
NUMBER_LIMIT="2-10"
NUMBER_LIMIT_IMPORTANT="4-10"

TIMELINE_CREATE="yes"
TIMELINE_LIMIT_HOURLY="0"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
```

- **Sin timeline:** `TIMELINE_CREATE="no"`. El script deshabilita `snapper-timeline.timer` y quedan solo los snapshots de DNF y los manuales.
- El script se puede volver a ejecutar: si la config de `root` ya existe, solo actualiza los valores.

Para cambiar la política después de instalar, sin volver a correr el script:

```bash
sudo snapper -c root set-config TIMELINE_LIMIT_DAILY=14
```

---

## 🧭 Uso básico

### Snapshots automáticos con DNF

Cada `dnf install`, `dnf upgrade` o `dnf remove`, y cada instalación desde Discover o GNOME Software, crea un par de snapshots pre/post.

En los ejemplos, los snapshots PRE y POST son el `1` y el `2`.

Ver qué cambió entre los dos:

```bash
snapper status 1..2
snapper diff 1..2 /etc/algun-archivo
```

Revertir todos los cambios de esa transacción:

```bash
sudo snapper undochange 1..2
```

Restaurar un solo archivo desde el snapshot `2` al estado actual (`0` es el sistema en vivo):

```bash
sudo snapper undochange 2..0 /etc/hosts
```

### Snapshots manuales pre/post

Útil antes de tocar algo importante del sistema (repos de terceros, cambios en `/etc`, drivers):

```bash
snapper -c root create -t pre -c number -d "Antes de probar X"
# ... hacés los cambios ...
snapper -c root create -t post --pre-number <pre> -c number -d "Después de probar X"
```

Para revertir:

```bash
sudo snapper -c root undochange <pre>..<post>
```

### Rollback completo con grub-btrfs

Cuando el sistema no arranca o necesitás volver todo atrás:

1. Reiniciá
2. En el menú de GRUB, entrá a **Fedora snapshots** y elegí el snapshot
3. Una vez dentro, abrí **Btrfs Assistant**
4. Elegí el snapshot y hacé **Restore**
5. Reiniciá

El snapshot se bootea en modo solo lectura con una capa overlay, así que los cambios que hagas en esa sesión no se guardan.

---

## ⬆️ Antes de un upgrade de versión de Fedora

```bash
snapper -c root create -t pre -c number -d "Antes de Fedora <N>"
```

Para tu home, hacé un backup antes (por ejemplo con Borg) de al menos `~/.config` y `~/.local/share`. Las aplicaciones suelen migrar su configuración al actualizarse, y un rollback del sistema no la vuelve atrás.

Después del upgrade:

```bash
snapper -c root create -t post --pre-number <pre> -c number -d "Después de Fedora <N>"
```

---

## 📦 Distrobox

- Los contenedores rootless viven en `~/.local/share/containers`, fuera de los snapshots de `root`. Un rollback del sistema no los toca.
- Si hacés backup de tu home, conviene excluir esa carpeta porque suele pesar varios GB:
  ```bash
  borg create ... --exclude ~/.local/share/containers
  ```
- `/var/lib/containers` (contenedores con root) está en su propio subvolumen en el layout de la guía, también fuera de los snapshots.

---

## 🩺 Solución de problemas

**El script se corta a mitad de camino.** Usa `set -euo pipefail` y se detiene en el primer error. Para ver exactamente dónde:

```bash
bash -x ./install.sh 2>&1 | tee install.log
```

**DNF no crea snapshots.** Verificá que exista el archivo de acciones:

```bash
ls -l /etc/dnf/libdnf5-plugins/actions.d/snapper.actions
```

**Quedó una config de `home` de una instalación anterior.** El script no la borra. Para eliminarla (borra sus snapshots, no tus archivos):

```bash
sudo snapper -c home delete-config
```

**`/.snapshots` existe pero no hay config de root.** Si está vacío, el script lo limpia solo. Si tiene contenido, frena para que lo revises a mano.

---

## 📄 Licencia y créditos

MIT, igual que el proyecto original.

Basado en [sysguides-snapper-fedora](https://github.com/SysGuides/sysguides-snapper-fedora) de Madhu Desai ([SysGuides](https://sysguides.com)). grub-btrfs es de [Antynea](https://github.com/Antynea/grub-btrfs).