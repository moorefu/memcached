#!/bin/bash
# 在 manylinux2014 (glibc 2.17) 容器内构建完全便携的 memcached。
#
# 便携性目标: 产物只依赖 glibc (>= 2.17), 其余依赖全部静态链入二进制:
#   - OpenSSL 1.1.1w        (--enable-tls)
#   - libevent 2.1.12       (核心依赖)
#   - libseccomp 2.5.5      (--enable-seccomp)
#   - cyrus-sasl 2.1.28     (--enable-sasl, PLAIN 认证机制直接编入二进制,
#                            目标机器无需安装任何 SASL 库或运行时插件)
#
# 用法: 在仓库根目录(容器内)执行  bash scripts/build-linux-portable.sh <版本号>
# 产出: memcached-<版本号>-linux-glibc2.17-<arch>.tar.gz (+ .sha256)
set -euo pipefail

VERSION="${1:?用法: $0 <memcached 版本号, 例如 1.6.41>}"
ARCH="$(uname -m)"
NPROC="$(nproc)"
DEPS=/tmp/deps

OPENSSL_VER=1.1.1w
LIBEVENT_VER=2.1.12-stable
LIBSECCOMP_VER=2.5.5
CYRUS_SASL_VER=2.1.28

log() { echo "==> $*"; }

# 源码包缓存: 若 $CACHE_DIR 已有所需 tar 包则直接复用(便于本地/离线构建),
# CI 等无缓存场景自动下载。
CACHE_DIR="${CACHE_DIR:-/workspace/deps-cache}"
download() {
    local url="$1" out
    out="$(basename "$url")"
    if [ -s "$CACHE_DIR/$out" ]; then
        echo "使用缓存: $CACHE_DIR/$out"
        cp "$CACHE_DIR/$out" "$out"
        return
    fi
    curl -fsSL -o "$out" "$url"
    mkdir -p "$CACHE_DIR"
    cp "$out" "$CACHE_DIR/$out" 2>/dev/null || true
}

# manylinux2014: 启用 devtoolset (新版 GCC, 但仍以 glibc 2.17 为链接基线)
# enable 脚本引用未定义变量, 需临时关闭 nounset
for dts in /opt/rh/devtoolset-*/enable; do
    if [ -f "$dts" ]; then set +u; . "$dts"; set -u; break; fi
done

log "安装构建工具"
yum install -y autoconf automake libtool gperf pkgconfig

mkdir -p "$DEPS"
cd "$DEPS"

# ---------- 静态 OpenSSL (manylinux2014 自带的 1.0.x 太旧) ----------
if [ ! -f "$DEPS/openssl/lib/libssl.a" ]; then
    log "编译静态 OpenSSL $OPENSSL_VER"
    download "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz"
    tar -xzf "openssl-$OPENSSL_VER.tar.gz"
    cd "openssl-$OPENSSL_VER"
    ./Configure "linux-$ARCH" no-shared --prefix="$DEPS/openssl" --openssldir="$DEPS/openssl"
    make -j"$NPROC"
    make install_sw
    cd "$DEPS"
fi

# ---------- 静态 libevent ----------
if [ ! -f "$DEPS/libevent/lib/libevent.a" ]; then
    log "编译静态 libevent $LIBEVENT_VER"
    download "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz"
    tar -xzf "libevent-$LIBEVENT_VER.tar.gz"
    cd "libevent-$LIBEVENT_VER"
    ./configure --disable-shared --enable-static --prefix="$DEPS/libevent" --disable-openssl
    make -j"$NPROC"
    make install
    cd "$DEPS"
fi

# ---------- 静态 libseccomp ----------
if [ ! -f "$DEPS/libseccomp/lib/libseccomp.a" ]; then
    log "编译静态 libseccomp $LIBSECCOMP_VER"
    download "https://github.com/seccomp/libseccomp/releases/download/v$LIBSECCOMP_VER/libseccomp-$LIBSECCOMP_VER.tar.gz"
    tar -xzf "libseccomp-$LIBSECCOMP_VER.tar.gz"
    cd "libseccomp-$LIBSECCOMP_VER"
    ./configure --disable-shared --enable-static --prefix="$DEPS/libseccomp"
    make -j"$NPROC"
    make install
    cd "$DEPS"
fi

# ---------- 静态 cyrus-sasl (PLAIN 机制编入库内) ----------
if [ ! -f "$DEPS/cyrus-sasl/lib/libsasl2.a" ]; then
    log "编译静态 cyrus-sasl $CYRUS_SASL_VER (PLAIN 机制内置)"
    download "https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-$CYRUS_SASL_VER/cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
    tar -xzf "cyrus-sasl-$CYRUS_SASL_VER.tar.gz"
    cd "cyrus-sasl-$CYRUS_SASL_VER"
    # 注意: 不能加 --with-pic —— dlopen.c 里的静态插件表只在非 PIC 编译时生效(#ifndef PIC),
    # 而 devtoolset 默认非 PIE, 非 PIC 静态库可以正常链入可执行文件。
    # 只保留 PLAIN/ANONYMOUS 机制, 关闭其余插件, 去掉外部数据库依赖。
    ./configure \
        --enable-static \
        --disable-shared \
        --prefix="$DEPS/cyrus-sasl" \
        --disable-sample \
        --disable-cram \
        --disable-digest \
        --disable-scram \
        --disable-otp \
        --disable-staticdlopen \
        --with-dblib=none
    make -j"$NPROC"
    make install
    cd "$DEPS"
fi

# 静态插件表是否真的包含 PLAIN
if ! nm "$DEPS/cyrus-sasl/lib/libsasl2.a" 2>/dev/null | grep -q 'plain_server_plug_init'; then
    echo "错误: PLAIN 机制未被编入静态 libsasl2.a" >&2
    exit 1
fi

# ---------- memcached ----------
log "编译 memcached $VERSION"
cd /workspace
git config --global --add safe.directory /workspace 2>/dev/null || true
./autogen.sh
# autogen.sh 会用 git describe 生成版本号, 这里强制覆盖为发布版本
echo "m4_define([VERSION_NUMBER], [$VERSION])" > version.m4
./configure \
    --with-libevent="$DEPS/libevent" \
    --with-libssl="$DEPS/openssl" \
    --enable-seccomp \
    --enable-tls \
    --enable-sasl \
    --enable-sasl-pwdb \
    CPPFLAGS="-I$DEPS/libseccomp/include -I$DEPS/cyrus-sasl/include" \
    LDFLAGS="-L$DEPS/libseccomp/lib -L$DEPS/cyrus-sasl/lib" \
    LIBS="-lpthread -ldl"
make -j"$NPROC"

# ---------- 便携性验证 ----------
log "检查动态依赖 (只允许 glibc 家族)"
ldd memcached
BAD="$(ldd memcached | awk '{print $1}' \
    | grep -vE 'linux-vdso|ld-linux|^libc\.so|^libpthread|^libdl|^libm\.so|^librt\.so|^libresolv|^libgcc_s' || true)"
if [ -n "$BAD" ]; then
    echo "错误: 存在 glibc 之外的动态依赖, 产物不便携: $BAD" >&2
    exit 1
fi

log "SASL PLAIN 认证功能测试"
PY="$(command -v python3 || command -v python2 || true)"
if [ -z "$PY" ]; then
    PY="$(ls /opt/python/cp3*/bin/python3 2>/dev/null | head -1 || true)"
fi
if [ -z "$PY" ]; then
    echo "错误: 容器内找不到 python, 无法执行 SASL 功能测试" >&2
    exit 1
fi
cat > /tmp/sasl_test.py <<'EOF'
import socket, struct, sys

HOST, PORT = '127.0.0.1', 11311

def send_pkt(s, opcode, key=b'', val=b''):
    total = len(key) + len(val)
    hdr = struct.pack('!BBHBBHIIQ', 0x80, opcode, len(key), 0, 0, 0, total, 0, 0)
    s.sendall(hdr + key + val)

def recv_pkt(s):
    hdr = b''
    while len(hdr) < 24:
        c = s.recv(24 - len(hdr))
        if not c: raise IOError('connection closed')
        hdr += c
    magic, op, keyl, extl, dtype, status, rest, opaque, cas = struct.unpack('!BBHBBHIIQ', hdr)
    body = b''
    while len(body) < rest:
        c = s.recv(rest - len(body))
        if not c: raise IOError('connection closed')
        body += c
    return status, body

# 1) list mechanisms: statically built-in PLAIN must be present
s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x20)                       # SASL list mechanisms (0x20)
status, body = recv_pkt(s)
if status != 0:
    sys.exit('FAIL: list mechanisms failed, status=%d' % status)
print('mechanisms:', body.split())
if b'PLAIN' not in body.split():
    sys.exit('FAIL: PLAIN mechanism missing')
s.close()

# 2) correct credentials must authenticate
s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x21, b'PLAIN', b'\x00testuser\x00testpass')
status, body = recv_pkt(s)
print('auth(correct password) status =', status)
if status != 0:
    sys.exit('FAIL: PLAIN auth failed with correct password, status=%d' % status)
s.close()

# 3) wrong credentials must be rejected
s = socket.create_connection((HOST, PORT), 5)
send_pkt(s, 0x21, b'PLAIN', b'\x00testuser\x00wrongpass')
status, body = recv_pkt(s)
print('auth(wrong password) status =', status)
if status == 0:
    sys.exit('FAIL: wrong password was accepted')
s.close()
print('SASL PLAIN: all tests passed')
EOF
printf 'testuser:testpass\n' > /tmp/memcached-sasl-pwdb
MEMCACHED_SASL_PWDB=/tmp/memcached-sasl-pwdb ./memcached -S -u root -p 11311 -U 0 -m 64 -v &
MC_PID=$!
trap 'kill $MC_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    if (exec 3<>/dev/tcp/127.0.0.1/11311) 2>/dev/null; then break; fi
    sleep 0.2
done
"$PY" /tmp/sasl_test.py
kill $MC_PID
trap - EXIT

# ---------- 打包 ----------
log "打包"
DIST="memcached-$VERSION-linux-glibc2.17-$ARCH"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/include" "$DIST/share/doc" "$DIST/share/man/man1"
cp memcached "$DIST/bin/"
cp scripts/memcached-tool "$DIST/bin/"
cp COPYING "$DIST/share/doc/LICENSE"
cp doc/memcached.1 "$DIST/share/man/man1/"
cat > "$DIST/share/doc/README.txt" <<EOF
memcached $VERSION 便携版 (Linux $ARCH, glibc >= 2.17)

标准前缀布局 (bin/include/share), 单二进制, 解压即用, 目标系统无需安装任何依赖库。
以下库已静态编译进 memcached 二进制:
  - OpenSSL $OPENSSL_VER        (TLS 支持, --enable-tls)
  - libevent $LIBEVENT_VER
  - libseccomp $LIBSECCOMP_VER  (seccomp 沙箱)
  - cyrus-sasl $CYRUS_SASL_VER  (SASL 认证, PLAIN 机制已内置, 无需系统 SASL 插件)
唯一的动态依赖是 glibc 本身 (CentOS/RHEL 7 及更新版本均可直接运行)。

基本用法:
  ./bin/memcached -u nobody -p 11211

SASL 认证 (-S, 二进制协议客户端):
  echo 'user:pass' > pwdb.txt
  MEMCACHED_SASL_PWDB=./pwdb.txt ./bin/memcached -S -u nobody

目录结构:
  bin/     memcached 主程序, memcached-tool 管理脚本(perl, 可选)
  include/ 占位 (memcached 无对外 API 头文件)
  share/   文档(doc), 手册页(man), LICENSE
EOF
tar czf "$DIST.tar.gz" "$DIST"
sha256sum "$DIST.tar.gz" > "$DIST.tar.gz.sha256"
log "完成: $PWD/$DIST.tar.gz"
