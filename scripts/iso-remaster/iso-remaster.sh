#! /bin/bash
set -eE
set -o pipefail

# TODO:
# - new mode using `udiskctl loop-setup` instead of `fuseiso`
# - maybe find workaround for iso-patcher to work in fuse mode
#   despite https://github.com/containers/fuse-overlayfs/issues/377

die() {
    echo >&2
    echo >&2 "ERROR: $*"
    echo >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [<options>] <input-iso> <output-iso>

Options:
  --mode <mode>   Force specified operation mode (default: use best available)
         fuse     : more resource-friendly, needs fuseiso and fuse-overlayfs
         copy     : more portable, needs more disk space, wears disk more
  --install-patcher, -l <script>
         Unpack install.img, run <script> with its location as single argument,
         and repack install.img for the output ISO
  --iso-patcher, -s <script>
         Run <script> with ISO contents location as single argument,
         before repacking output ISO.
         Forces "--mode copy" to avoid fuse-overlay bug
         https://github.com/containers/fuse-overlayfs/issues/377
  -z [bzip2|gzip]
         Compression method used by install.img (default: bzip2)
  -V <volume-id>  Use specified volume id instead of reusing the original one
EOF
}

die_usage() {
    usage >&2
    die "$*"
}

[ $(whoami) != root ] || die "not meant to run as root"


# select default operating mode
OPMODE=fuse
command -v fuseiso >/dev/null || { echo >&2 "fuseiso not found"; OPMODE=copy; }
command -v fuse-overlayfs >/dev/null || { echo >&2 "fuse-overlayfs not found"; OPMODE=copy; }

command -v 7z >/dev/null || die "required tool not found: 7z (e.g. p7zip-plugins in EPEL)"
command -v bzcat >/dev/null || die "required tool not found: bzip2"
command -v fakeroot >/dev/null || die "required tool not found: fakeroot"
command -v genisoimage >/dev/null || die "required tool not found: genisoimage"
command -v isohybrid >/dev/null || die "required tool not found: isohybrid (package syslinux-utils or syslinux)"
command -v isoinfo >/dev/null || die "required tool not found: isoinfo (package cdrkit-isotools or genisoimage?)"

ISOPATCHER=""
IMGPATCHER=""
VOLID=""
COMPRESS="bzip2"
while [ $# -ge 1 ]; do
    case "$1" in
        --mode)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            OPMODE="$2"
            shift
            ;;
        --iso-patcher|-s)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            ISOPATCHER="$2"
            echo >&2 "NOTE: iso-patcher use, forcing 'copy' mode"
            OPMODE=copy
            shift
            ;;
        --install-patcher|-l)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            IMGPATCHER="$2"
            shift
            ;;
        -V)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            VOLID="$2"
            shift
            ;;
        -z)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            COMPRESS="$2"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            die_usage "unknown flag '$1'"
            ;;
        *)
            break
            ;;
    esac
    shift
done

case "$COMPRESS" in
    bzip2) ZCAT=bzcat; ZIP=bzip2 ;;
    gzip) ZCAT=zcat; ZIP=gzip ;;
    *) die_usage "unsupported compression method" ;;
esac

[ $# = 2 ] || die_usage "need exactly 2 non-option arguments"

INISO="$1"
OUTISO="$2"

[ -r "$INISO" ] || die_usage "input ISO '$INISO' cannot be read"

umountrm() {
    sync "$1"
    fusermount -u -z "$1"
    rmdir "$1"
}

USERMOUNTS=()
exitcleanup() {
    set +e
    case $OPMODE in
        copy)
            rm -rf "$RWISO"
            ;;
        fuse)
            for MOUNT in "${USERMOUNTS[@]}"; do
                umountrm "$MOUNT"
            done
            rm -rf "$OVLRW" "$OVLWD"
            ;;
        *)
            die "unknown mode '$OPMODE'"
            ;;
    esac
    rm -rf "$INSTALLIMG"
    rm "$FAKEROOTSAVE"
}

trap 'exitcleanup' EXIT INT

# (absolute path) where we unpack install.img
INSTALLIMG=$(mktemp -d -p "$PWD" installimg.XXXXXX)

# (absolute path) where we get a RW copy of input ISO contents
RWISO=$(mktemp -d -p "$PWD" isorw.XXXXXX)


# allow successive fakeroot calls to act as a single session
FAKEROOTSAVE=$(realpath $(mktemp fakerootsave.XXXXXX))
touch "$FAKEROOTSAVE" # avoid "does not exist" warning on first use
FAKEROOT=(fakeroot -i "$FAKEROOTSAVE" -s "$FAKEROOTSAVE" --)


### produce patched iso contents in $RWISO

# provide a RW view of ISO

case $OPMODE in
copy)
    7z x "$INISO" -o"$RWISO"
    rm -rfv "$RWISO/[BOOT]"
    SRCISO="$RWISO"
    DESTISO="$RWISO"
    ;;
fuse)
    MNT=$(mktemp -d isomnt.XXXXXX)
    OVLRW=$(mktemp -d ovlfs-upper.XXXXXX)
    OVLWD=$(mktemp -d ovlfs-work.XXXXXX)
    fuseiso "$INISO" "$MNT"
    MOUNTS+=("$MNT")

    # genisoimage apparently needs write access to those
    mkdir -p "$OVLRW/boot/isolinux"
    cp "$MNT/boot/isolinux/isolinux.bin" "$OVLRW/boot/isolinux/"
    chmod +w "$OVLRW/boot/isolinux/isolinux.bin"

    SRCISO="$MNT"
    DESTISO="$OVLRW"
    ;;
*)
    die "unknown mode '$OPMODE'"
    ;;
esac

# maybe run install.img patcher

if [ -n "$IMGPATCHER" ]; then
    bzcat "$SRCISO/install.img" | (cd "$INSTALLIMG" && "${FAKEROOT[@]}" cpio -idm)

    # patch install.img contents
    "${FAKEROOT[@]}" "$IMGPATCHER" "$INSTALLIMG" || die "IMG patcher exited in error: $?"

    # repack install.img
    (cd "$INSTALLIMG" && "${FAKEROOT[@]}" sh -c "find . | cpio -o -H newc") |
        bzip2 > "$DESTISO/install.img"
fi

# produce merged view

case $OPMODE in
copy)
    ;;
fuse)
    # produce a merged iso tree
    fuse-overlayfs -o lowerdir="$MNT" -o upperdir="$OVLRW" -o workdir="$OVLWD" "$RWISO"
    MOUNTS+=("$RWISO")
    ;;
*)
    die "unknown mode '$OPMODE'"
    ;;
esac

if [ -n "$ISOPATCHER" ]; then
    "${FAKEROOT[@]}" "$ISOPATCHER" "$RWISO" || die "ISO patcher exited in error: $?"
fi

# default value for volume id
: ${VOLID:=$(isoinfo -i "$INISO" -d | grep "Volume id" | sed "s/Volume id: //")}

if [ -e "$RWISO/boot/efiboot.img" ]; then
    GENISOIMAGE_EXTRA_ARGS=(
        -eltorito-alt-boot
        -e boot/efiboot.img
        -no-emul-boot
    )
    ISOHYBRID_EXTRA_ARGS=(--uefi)
    is_efi=1
else
    echo >&2 "WARNING: no UEFI boot support"
    GENISOIMAGE_EXTRA_ARGS=()
    ISOHYBRID_EXTRA_ARGS=()
    is_efi=0
fi

"${FAKEROOT[@]}" genisoimage \
    -o "$OUTISO" \
    -v -r -J --joliet-long -V "$VOLID" -input-charset utf-8 \
    -c boot/isolinux/boot.cat -b boot/isolinux/isolinux.bin -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    \
    "${GENISOIMAGE_EXTRA_ARGS[@]}" \
    \
    "$RWISO"

isohybrid "${ISOHYBRID_EXTRA_ARGS[@]}" "$OUTISO"
