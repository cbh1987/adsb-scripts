#!/bin/bash
set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR
renice 10 $$

cd /tmp

repo="https://github.com/wiedehopf/adsb-scripts"
ipath=/usr/local/share/adsb-scripts
stuff="git cmake zlib1g-dev"
branch="master"

if [[ -n $1 ]]; then
    branch="$1"
fi

apt install -y $stuff || apt update && apt install -y $stuff || true

mkdir -p $ipath

function getGIT() {
    # getGIT $REPO $BRANCH $TARGET (directory)
    if [[ -z "$1" ]] || [[ -z "$2" ]] || [[ -z "$3" ]]; then echo "getGIT wrong usage, check your script or tell the author!" 1>&2; return 1; fi
    REPO="$1"; BRANCH="$2"; TARGET="$3"; pushd .
    if cd "$TARGET" &>/dev/null && git fetch --depth 1 origin "$BRANCH" && git reset --hard FETCH_HEAD; then popd; return 0; fi
    if ! cd /tmp || ! rm -rf "$TARGET"; then popd; return 1; fi
    if git clone --depth 1 --single-branch --branch "$2" "$1" "$3"; then popd; return 0; fi
    popd; return 1;
}

# get adsb-scripts repo
getGIT "$repo" master "$ipath/git"

cd "$ipath/git/libacars"

GIT="$ipath/libacars-git"
getGIT https://github.com/szpajder/libacars "$branch" "$GIT"

cd "$GIT"

rm -rf build
mkdir build
cd build

cmake -DCMAKE_BUILD_TYPE=Release ..

make -j2

make install

ldconfig

touch "$ipath/libacars-installed"
