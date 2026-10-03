#!/bin/sh
# Package the application or its source using the native command-line tools.
set -eu

usage()
{
    echo "Usage: /bin/sh $0 app APP_DIRECTORY ARCHIVE.tar.gz" >&2
    echo "       /bin/sh $0 source ARCHIVE.tar.gz" >&2
    exit 1
}

make_directory()
{
    # The old shell does not restore function arguments after recursive calls.
    (
        test -d "$1" && exit 0
        directory_target=$1
        directory_parent=`dirname "$directory_target"`
        make_directory "$directory_parent"
        mkdir "$directory_target"
    )
}

test "$#" -gt 0 || usage
kind=$1
shift
case "$kind" in
    app)
        test "$#" -eq 2 || usage
        app=$1
        archive=$2
        ;;
    source)
        test "$#" -eq 1 || usage
        archive=$1
        ;;
    *) usage ;;
esac

script_dir=`dirname "$0"`
script_dir=`cd "$script_dir" && pwd`
source_dir=`cd "$script_dir/.." && pwd`
case "$archive" in
    /*) ;;
    *) archive="`pwd`/$archive" ;;
esac
if test -d "$archive"; then
    echo "Archive path is a directory: $archive" >&2
    exit 1
fi
archive_dir=`dirname "$archive"`
make_directory "$archive_dir"
work="$archive.tmp.$$"
# A fresh directory keeps prior packages and local game data out of the archive.
(umask 077; mkdir "$work")
# Its EXIT trap can also see status zero after an errexit inside a function.
package_status=1
trap 'trap 0; rm -rf "$work"; exit $package_status' 0
trap 'package_status=1; exit 1' 1 2 3 15
umask 022

case "$kind" in
    app)
        mkdir "$work/quake2.app" "$work/quake2.app/baseq2"
        cp "$app/quake2" "$work/quake2.app/quake2"
        cp "$app/icon.tiff" "$work/quake2.app/icon.tiff"
        strip -S "$work/quake2.app/quake2"
        tr -d '\015' < "$script_dir/README.txt" > "$work/quake2.app/README.txt"
        tr -d '\015' < "$source_dir/gnu.txt" > "$work/quake2.app/COPYING"
        tr -d '\015' < "$script_dir/config.cfg" > "$work/quake2.app/baseq2/config.cfg"
        chmod 755 "$work/quake2.app/quake2"
        chmod 644 "$work/quake2.app/icon.tiff" "$work/quake2.app/README.txt" \
            "$work/quake2.app/COPYING" "$work/quake2.app/baseq2/config.cfg"
        (cd "$work" && tar cf archive.tar quake2.app)
        ;;
    source)
        cd "$source_dir"
        echo gnu.txt > "$work/files"
        echo readme.txt >> "$work/files"
        find client game qcommon ref_soft server null linux openstep \
            \( -name output -o -name __pycache__ -o -name '*.app' \) -prune \
            -o -type f -print >> "$work/files"
        mkdir "$work/source"
        while IFS= read file; do
            case "$file" in
                *.c|*.h|*.m|*.s|*.asm|*.inc|*.def|*.dsp|*.sh|*.txt|*.cfg|\
                *.openstep|*.iconheader|*/Makefile*|*/README*|*.3dfxgl)
                    text=yes ;;
                *.tiff|*.gif) text=no ;;
                *) continue ;;
            esac
            directory=`dirname "$file"`
            make_directory "$work/source/$directory"
            if test "$text" = yes; then
                tr -d '\015' < "$file" > "$work/source/$file"
            else
                cp "$file" "$work/source/$file"
            fi
            chmod 644 "$work/source/$file"
        done < "$work/files"
        (cd "$work/source" && tar cf "$work/archive.tar" \
            gnu.txt readme.txt client game qcommon ref_soft server null linux openstep)
        ;;
esac

# Separate steps ensure a failed tar or gzip cannot replace a good archive.
gzip -n -c "$work/archive.tar" > "$work/archive.tar.gz"
chmod 644 "$work/archive.tar.gz"
mv -f "$work/archive.tar.gz" "$archive"
echo "Created $archive"
package_status=0
