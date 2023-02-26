#!/bin/bash

if [ "$(id -u)" != "0" ]; then
    echo -e "\033[33m"
    echo "此脚本必须使用 sudo 或以 root 身份运行。"
    echo -e "\033[37m"
    exit 1
fi

sed -i 's#raspbian.raspberrypi.org#mirrors.tuna.tsinghua.edu.cn/raspberry-pi-os#g' /etc/apt/sources.list

sed -i '1 i\deb-src http://mirrors.tuna.tsinghua.edu.cn/raspberry-pi-os/raspbian/ bullseye main non-free contrib rpi' /etc/apt/sources.list

sed -i 's#archive.raspberrypi.org/debian/ buster main#mirrors.tuna.tsinghua.edu.cn/raspberrypi/ bullseye main ui#g' /etc/apt/sources.list.d/raspi.list

apt update

set -e
trap 'echo "[错误] 第 $LINENO 行命令在执行 $BASH_COMMAND 时出现错误"' ERR
renice 10 $$

repository="https://gitee.com/smallmeng/readsb.git"

# blacklist kernel driver as on ancient systems
if grep -E 'wheezy|jessie' /etc/os-release -qs; then
    echo -e 'blacklist rtl2832\nblacklist dvb_usb_rtl28xxu\nblacklist rtl8192cu\nblacklist rtl8xxxu\n' > /etc/modprobe.d/blacklist-rtl-sdr.conf
    rmmod rtl2832 &>/dev/null || true
    rmmod dvb_usb_rtl28xxu &>/dev/null || true
    rmmod rtl8xxxu &>/dev/null || true
    rmmod rtl8192cu &>/dev/null || true
fi

ipath=/usr/local/share/adsb-wiki/readsb-install
mkdir -p $ipath

if grep -E 'wheezy|jessie' /etc/os-release -qs; then
    # make sure the rtl-sdr rules are present on ancient systems
    wget -O /tmp/rtl-sdr.rules https://gitee.com/smallmeng/adsb-scripts/raw/master/osmocom-rtl-sdr.rules
    cp /tmp/rtl-sdr.rules /etc/udev/rules.d/
fi

function aptInstall() {
    if ! apt install -y --no-install-recommends --no-install-suggests "$@" &>/dev/null; then
        apt update
        if ! apt install -y --no-install-recommends --no-install-suggests "$@"; then
            apt clean -y || true
            apt --fix-broken install -y || true
            apt install --no-install-recommends --no-install-suggests -y $packages
        fi
    fi
}

if command -v apt &>/dev/null; then
    packages=(git gcc make libusb-1.0-0-dev librtlsdr-dev librtlsdr0 ncurses-dev ncurses-bin zlib1g-dev zlib1g)
    if ! grep -E 'wheezy|jessie' /etc/os-release -qs; then
        packages+=(libzstd-dev libzstd1)
    fi
    if ! command -v nginx &>/dev/null; then
        packages+=(lighttpd)
    fi
    aptInstall "${packages[@]}"
fi

udevadm control --reload-rules || true

function getGIT() {
    # getGIT $REPO $BRANCH $TARGET-DIR
    if [[ -z "$1" ]] || [[ -z "$2" ]] || [[ -z "$3" ]]; then
        echo "getGIT wrong usage, check your script or tell the author!" 1>&2
        return 1
    fi
    if ! cd "$3" &>/dev/null || ! git fetch --depth 2 origin "$2" || ! git reset --hard FETCH_HEAD; then
        if ! rm -rf "$3" || ! git clone --depth 2 --single-branch --branch "$2" "$1" "$3"; then
            return 1
        fi
    fi
    return 0
}
BRANCH="stale"
if grep -E 'wheezy|jessie' /etc/os-release -qs; then
    BRANCH="jessie"
fi
if ! getGIT "$repository" "$BRANCH" "$ipath/git"
then
    echo "无法使用 git clone 命令克隆此仓库"
    exit 1
fi

rm -rf "$ipath"/readsb*.deb
cd "$ipath/git"

make clean
THREADS=$(( $(grep -c ^processor /proc/cpuinfo) - 1 ))
THREADS=$(( THREADS > 0 ? THREADS : 1 ))
CFLAGS="-O2 -march=native"

# disable unaligned access for arm 32bit ...
if uname -m | grep -qs -e arm -e aarch64 && gcc -mno-unaligned-access hello.c -o /dev/null &>/dev/null; then
    CFLAGS+=" -mno-unaligned-access"
fi

if [[ $1 == "sanitize" ]]; then
    CFLAGS+="-fsanitize=address -static-libasan"
    if ! make "-j${THREADS}" AIRCRAFT_HASH_BITS=16 RTLSDR=yes OPTIMIZE="$CFLAGS"; then
        if grep -qs /etc/os-release 'bullseye'; then apt install -y libasan6;
        elif grep -qs /etc/os-release 'buster'; then apt install -y libasan5;
        fi
        make "-j${THREADS}" AIRCRAFT_HASH_BITS=16 RTLSDR=yes OPTIMIZE="$CFLAGS"
    fi
else
    make "-j${THREADS}" AIRCRAFT_HASH_BITS=16 RTLSDR=yes OPTIMIZE="$CFLAGS" "$@"
fi

cp -f debian/readsb.service /lib/systemd/system/readsb.service

rm -f /usr/bin/readsb /usr/bin/viewadsb
cp -f readsb /usr/bin/readsb
cp -f viewadsb /usr/bin/viewadsb

cp -n debian/readsb.default /etc/default/readsb

if ! id -u readsb &>/dev/null
then
    adduser --system --home $ipath --no-create-home --quiet readsb || adduser --system --home-dir $ipath --no-create-home readsb
    adduser readsb plugdev || true # USB access
    adduser readsb dialout || true # serial access
fi

apt remove -y dump1090-fa &>/dev/null || true
systemctl disable --now dump1090-mutability &>/dev/null || true
systemctl disable --now dump1090 &>/dev/null || true

rm -f /etc/lighttpd/conf-enabled/89-dump1090.conf

systemctl enable readsb
systemctl restart readsb || true

# script to change gain

mkdir -p /usr/local/bin
cat >/usr/local/bin/readsb-gain <<"EOF"
#!/bin/bash
validre='^(-10|[0-9]+([.][0-9]+)?)$'
gain=$(echo $1 | tr -cd '[:digit:].-')
if ! [[ $gain =~ $validre ]] ; then echo "Error, invalid gain!"; exit 1; fi
if ! grep gain /etc/default/readsb &>/dev/null; then sudo sed -i -e 's/RECEIVER_OPTIONS="/RECEIVER_OPTIONS="--gain 49.6 /' /etc/default/readsb; fi
sudo sed -i -E -e "s/--gain .?[0-9]*.?[0-9]* /--gain $gain /" /etc/default/readsb
sudo systemctl restart readsb
EOF
chmod a+x /usr/local/bin/readsb-gain


# set-location
cat >/usr/local/bin/readsb-set-location <<"EOF"
#!/bin/bash

lat=$(echo $1 | tr -cd '[:digit:].-')
lon=$(echo $2 | tr -cd '[:digit:].-')

if ! awk "BEGIN{ exit ($lat > 90) }" || ! awk "BEGIN{ exit ($lat < -90) }"; then
    echo
    echo "Invalid latitude: $lat"
    echo "Latitude must be between -90 and 90"
    echo
    echo "Example format for latitude: 51.528308"
    echo
    echo "Usage:"
    echo "readsb-set-location 51.52830 -0.38178"
    echo
    exit 1
fi
if ! awk "BEGIN{ exit ($lon > 180) }" || ! awk "BEGIN{ exit ($lon < -180) }"; then
    echo
    echo "Invalid longitude: $lon"
    echo "Longitude must be between -180 and 180"
    echo
    echo "Example format for latitude: -0.38178"
    echo
    echo "Usage:"
    echo "readsb-set-location 51.52830 -0.38178"
    echo
    exit 1
fi

echo
echo "setting Latitude: $lat"
echo "setting Longitude: $lon"
echo
if ! grep -e '--lon' /etc/default/readsb &>/dev/null; then sed -i -e 's/DECODER_OPTIONS="/DECODER_OPTIONS="--lon -0.38178 /' /etc/default/readsb; fi
if ! grep -e '--lat' /etc/default/readsb &>/dev/null; then sed -i -e 's/DECODER_OPTIONS="/DECODER_OPTIONS="--lat 51.52830 /' /etc/default/readsb; fi
sed -i -E -e "s/--lat .?[0-9]*.?[0-9]* /--lat $lat /" /etc/default/readsb
sed -i -E -e "s/--lon .?[0-9]*.?[0-9]* /--lon $lon /" /etc/default/readsb
systemctl restart readsb
EOF
chmod a+x /usr/local/bin/readsb-set-location


echo --------------
cd "$ipath"

wget -O tar1090-install.sh https://gitee.com/smallmeng/tar1090-en/raw/master/install.sh
bash tar1090-install.sh /run/readsb

rm -rf /etc/motd
wget -P /etc https://gitee.com/smallmeng/files/raw/master/motd

if ! systemctl show readsb | grep 'ExecMainStatus=0' -qs; then
        echo
        echo "             readsb+tar1090 已经安装完成！但是目前 readsb 服务未运行！"
        echo "                       因此需要重启设备以启动 readsb 服务"
        echo "                 tar1090的Web页面为 http://$(ip route get 1.2.3.4 | grep -m1 -o -P 'src \K[0-9,.]*')/tar1090"
        echo "                     Web界面将显示错误，直至 readsb 正常运行"
        echo
        echo
        echo "                     不要忘记使用十进制纬度和经度设置您的位置"
        echo "                                    例如:"
        echo "                   sudo readsb-set-location 50.12344 10.23429"
        echo 
        echo "                               ！！！注意！！！ "        
        echo "                             请不要尝试将数据传给"
        echo "      Flightradar24、Flightaware、PlaneFinder、RadarBox等境外飞机跟踪网站"
        echo "                   这种行为严重违反《中华人民共和国无线电管理条例》"
        echo
    fi