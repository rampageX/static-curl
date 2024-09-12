#!/bin/sh

#Build Static curl ${arch} Binary
#Rip from https://github.com/stunnel/static-curl

#openssl version may not work, try ngtcp2 version first.
#* Host www.zhihu.com:443 was resolved.
#* IPv6: (none)
#* IPv4: 120.232.207.107, 120.240.101.99, 111.45.69.246
#*   Trying 120.232.207.107:443...
#* error:80000026:system library::Function not implemented
#* QUIC connect to 120.232.207.107 port 443 failed: Could not connect to server
#*   Trying 120.240.101.99:443...
#* error:80000026:system library::Function not implemented
#* QUIC connect to 120.240.101.99 port 443 failed: Could not connect to server
#*   Trying 111.45.69.246:443...
#* error:80000026:system library::Function not implemented
#* QUIC connect to 111.45.69.246 port 443 failed: Could not connect to server
#* Failed to connect to www.zhihu.com port 443 after 23 ms: Could not connect to server
#* closing connection #0
#curl: (7) error:80000026:system library::Function not implemented

set -ex

TLS_LIB=
QUICTLS_TAG=
OPENSSL_TAG=
ZLIB_TAG=
LIBATOMIC_OPS_TAG=
LIBXML_TAG=
NGTCP2_TAG=
NGHTTP2_TAG=
NGHTTP3_TAG=
LIBUNISTRING_TAG=
LIBIDN2_TAG=
LIBOSL_TAG=
BROTLI_TAG=
ZSTD_TAG=
LIBSSH2_TAG=

CURL_TAG=8.10.0
ENABLE_TRURL=0

STANDARD="c++17"

arch="armv5te"
arch_build="arm"
openssl_arch="linux-armv4"
host="arm-linux-musleabi"
base_dir=$(cd $(dirname $0) && pwd)
data_dir="${base_dir}/data"
install_dir="${base_dir}/${arch}_dev"
include_dir="${install_dir}/include"
lib_dir="${install_dir}/lib"
result_dir="${base_dir}/${arch}_result"

custom_flags_set() {
    CXXFLAGS="-std=${STANDARD}"
    CPPFLAGS="--static -static -I${include_dir}"
    LDFLAGS="--static -static -Wl,--no-as-needed -L${lib_dir}"
    LIBS="-lpthread -pthread"
    LD_LIBRARY_PATH="-L${lib_dir}"
    PKG_CONFIG_PATH="${lib_dir}/pkgconfig"
}

custom_flags_reset() {
    CXXFLAGS="-std=${STANDARD}"
    CPPFLAGS=""
    LDFLAGS=""
}

custom_flags_reset

alpine_init() {
    apk update;
    apk upgrade;
    apk add \
    build-base clang automake cmake autoconf libtool binutils linux-headers \
    curl wget git jq xz grep sed groff gnupg perl python3 \
    ca-certificates ca-certificates-bundle \
    cunit-dev \
    zlib-static zlib-dev \
    libunistring-static libunistring-dev \
    libidn2-static libidn2-dev \
    libpsl-static libpsl-dev \
    zstd-static zstd-dev;
}

clean_folder() {
    cd ${data_dir}
    #delete folders only, keep the files.
    find -mindepth 1 -maxdepth 1 -type d -exec rm -r {} \;
    #delete wrong cache
    local openssl_cache_file="${data_dir}/github-openssl.json"
    local tls_now="$(grep quictls/openssl ${openssl_cache_file})"
    if [ "${TLS_LIB}" = "openssl" ]; then
        if [ -n "$tls_now" ]; then rm -f ${openssl_cache_file}; fi
    else
        if [ -z "$tls_now" ]; then rm -f ${openssl_cache_file}; fi
    fi
}

_get_github() {
    local repo release_file auth_header status_code size_of
    repo=$1
    release_file="github-${repo#*/}.json"

    # GitHub API has a limit of 60 requests per hour, cache the results.
    echo "Downloading ${repo} releases from GitHub"
    echo "URL: https://api.github.com/repos/${repo}/releases"

    # get token from github settings
    auth_header=""
    set +o xtrace
    if [ -n "${TOKEN_READ}" ]; then
        auth_header="token ${TOKEN_READ}"
    fi

    status_code=$(curl --retry 5 --retry-max-time 120 "https://api.github.com/repos/${repo}/releases" \
        -w "%{http_code}" \
        -o "${release_file}" \
        -H "Authorization: ${auth_header}" \
        -s -L --compressed)

    set -o xtrace
    size_of=$(stat -c "%s" "${release_file}")
    if [ "${size_of}" -lt 200 ] || [ "${status_code}" -ne 200 ]; then
        echo "The release of ${repo} is empty, download tags instead."
        set +o xtrace
        status_code=$(curl --retry 5 --retry-max-time 120 "https://api.github.com/repos/${repo}/tags" \
            -w "%{http_code}" \
            -o "${release_file}" \
            -H "Authorization: ${auth_header}" \
            -s -L --compressed)
        set -o xtrace
    fi
    auth_header=""

    if [ "${status_code}" -ne 200 ]; then
        echo "ERROR. Failed to download ${repo} releases from GitHub, status code: ${status_code}"
        cat "${release_file}"
        exit 1
    fi
}

_get_tag() {
    # Function to get the latest tag based on given criteria
    jq -c -r "[.[] | select(${2})][0]" "${1}" > /tmp/tmp_release.json;
}

_get_latest_tag() {
    local release_file release_json
    release_file=$1

    # Get the latest tag that is not a draft and not a pre-release
    _get_tag "${release_file}" "(.prerelease != true) and (.draft != true)"

    release_json=$(cat /tmp/tmp_release.json)

    # If no tag found, get the latest tag that is not a draft
    if [ "${release_json}" = "null" ] || [ -z "${release_json}" ]; then
        _get_tag "${release_file}" ".draft != true"
        release_json=$(cat /tmp/tmp_release.json)
    fi

    # If still no tag found, get the first tag
    if [ "${release_json}" = "null" ] || [ -z "${release_json}" ]; then
        _get_tag "${release_file}" "."
    fi
}

url_from_github() {
    local browser_download_urls browser_download_url url repo version tag_name release_file
    repo=$1
    version=$2
    release_file="github-${repo#*/}.json"

    if [ ! -f "${release_file}" ]; then
        _get_github "${repo}"
    fi

    if [ -z "${version}" ]; then
        _get_latest_tag "${release_file}"
    else
        jq -c -r "map(select(.tag_name == \"${version}\")
                  // select(.tag_name | startswith(\"${version}\"))
                  // select(.tag_name | endswith(\"${version}\"))
                  // select(.tag_name | contains(\"${version}\"))
                  // select(.name == \"${version}\")
                  // select(.name | startswith(\"${version}\"))
                  // select(.name | endswith(\"${version}\"))
                  // select(.name | contains(\"${version}\")))[0]" \
            "${release_file}" > /tmp/tmp_release.json
    fi

    browser_download_urls=$(jq -r '.assets[]' /tmp/tmp_release.json | grep browser_download_url || true)

    if [ -n "${browser_download_urls}" ]; then
        suffixes="tar.xz tar.gz tar.bz2 tgz"
        for suffix in ${suffixes}; do
            browser_download_url=$(printf "%s" "${browser_download_urls}" | grep "${suffix}\"" || true)
            [ -n "$browser_download_url" ] && break
        done

        url=$(printf "%s" "${browser_download_url}" | head -1 | awk '{print $2}' | sed 's/"//g' || true)
    fi

    if [ -z "${url}" ]; then
        tag_name=$(jq -r '.tag_name // .name' /tmp/tmp_release.json | head -1)
        # get from "Source Code" of releases
        if [ "${tag_name}" = "null" ] || [ "${tag_name}" = "" ]; then
            echo "ERROR. Failed to get the ${version} from ${repo} of GitHub"
            exit 1
        fi
        url="https://github.com/${repo}/archive/refs/tags/${tag_name}.tar.gz"
    fi

    rm -f /tmp/tmp_release.json;
    URL="${url}"
}

download_and_extract() {
    echo "Downloading $1"
    local url

    url="$1"
    FILENAME=${url##*/}

    if [ ! -f "${FILENAME}" ]; then
        wget -c --no-verbose --content-disposition "${url}";

        FILENAME=$(curl --retry 5 --retry-max-time 120 -sIL "${url}" | \
            sed -n -e 's/^Content-Disposition:.*filename=//ip' | \
            tail -1 | sed 's/\r//g; s/\n//g; s/\"//g' | grep -oP '[\x20-\x7E]+' || true)
        if [ "${FILENAME}" = "" ]; then
            FILENAME=${url##*/}
        fi

        echo "Downloaded ${FILENAME}"
    else
        echo "Already downloaded ${FILENAME}"
    fi

    # If the file is a tarball, extract it
    if expr "${FILENAME}" : '.*\.\(tar\.xz\|tar\.gz\|tar\.bz2\|tgz\)$' > /dev/null; then
        # SOURCE_DIR=$(echo "${FILENAME}" | sed -E "s/\.tar\.(xz|bz2|gz)//g" | sed 's/\.tgz//g')
        SOURCE_DIR=$(tar -tf "${FILENAME}" | head -n 1 | cut -d'/' -f1)
        [ -d "${SOURCE_DIR}" ] && rm -rf "${SOURCE_DIR}"
        tar -axf "${FILENAME}"
        cd "${SOURCE_DIR}"
    fi
}

change_dir() {
    cd ${data_dir}
}

_copy_license() {
    # $1: original file name; $2: target file name
    mkdir -p "${install_dir}/licenses/";
    cp -p "${1}" "${install_dir}/licenses/${2}";
}

compile_zlib() {
    echo "Compiling zlib, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github madler/zlib "${ZLIB_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    custom_flags_set
    make clean || true
    CC=${host}-gcc ./configure --prefix=${install_dir} --static
    make -j"$(nproc)" CXXFLAGS="${CXXFLAGS}" CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}"
    make install
    custom_flags_reset

    _copy_license LICENSE zlib;
}

compile_libunistring() {
    echo "Compiling libunistring, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    [ -z "${LIBUNISTRING_TAG}" ] && LIBUNISTRING_TAG="latest"
    url="https://mirrors.kernel.org/gnu/libunistring/libunistring-${LIBUNISTRING_TAG}.tar.xz"
    download_and_extract "${url}"

    #custom_flags_set
    ./configure --host "${host}" --prefix="${install_dir}" --disable-rpath --disable-shared
    make -j "$(nproc)";
    make install;

    _copy_license COPYING libunistring;
}

compile_libidn2() {
    echo "Compiling libidn2, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    [ -z "${LIBIDN2_TAG}" ] && LIBIDN2_TAG="latest"
    url="https://mirrors.kernel.org/gnu/libidn/libidn2-${LIBIDN2_TAG}.tar.gz"
    download_and_extract "${url}"

    PKG_CONFIG="pkg-config --static --with-path=${install_dir}/lib/pkgconfig:${install_dir}/lib64/pkgconfig" \
    LDFLAGS="${LDFLAGS} --static" \
    ./configure \
        --host "${host}" \
        --with-libunistring-prefix="${install_dir}" \
        --prefix="${install_dir}" \
        --disable-shared;
    make -j "$(nproc)";
    make install;

    _copy_license COPYING libidn2;
}

compile_libpsl() {
    echo "Compiling libpsl, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github rockdaboot/libpsl "${LIBPSL_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    PKG_CONFIG="pkg-config --static --with-path=${install_dir}/lib/pkgconfig:${install_dir}/lib64/pkgconfig" \
    LDFLAGS="${LDFLAGS} --static" \
      ./configure --host="${host}" --prefix="${install_dir}" \
        --enable-static --enable-shared=no --enable-builtin --disable-runtime;

    make -j "$(nproc)" LDFLAGS="-static -all-static -Wl,-s ${LDFLAGS}";
    make install;

    _copy_license LICENSE libpsl;
}

compile_ares() {
    echo "Compiling c-ares, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github c-ares/c-ares "${ARES_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    ./configure --host="${host}" --prefix="${install_dir}" --enable-static --disable-shared;
    make -j "$(nproc)";
    make install;

    _copy_license LICENSE.md c-ares;
}

compile_tls() {
    echo "Compiling ${TLS_LIB}, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    if [ "${TLS_LIB}" = "openssl" ]; then
        url_from_github openssl/openssl "${OPENSSL_TAG}"
    else
        url_from_github quictls/openssl "${QUICTLS_TAG}"
    fi

    url="${URL}"
    download_and_extract "${url}"

    #custom_flags_reset
    #custom_flags_set
    make clean || true
    ./Configure \
        ${openssl_arch} \
        --cross-compile-prefix=${host}- --prefix=${install_dir} \
        -fPIC \
        --prefix="${install_dir}" \
        threads no-shared \
        enable-ktls \
        enable-tls1_3 \
        enable-ssl3 enable-ssl3-method \
        enable-des enable-rc4 \
        enable-weak-ssl-ciphers \
        --static -static
        #CXXFLAGS="${CXXFLAGS}" CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}"

    make -j "$(nproc)";
    make install_sw;

    _copy_license LICENSE.txt openssl;
}

compile_libssh2() {
    echo "Compiling libssh2, Arch: ${arch}" | tee "${result_dir}/running"

    local url
    change_dir;

    url_from_github libssh2/libssh2 "${LIBSSH2_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    autoreconf -fi
    PKG_CONFIG="pkg-config --static --with-path=${install_dir}/lib/pkgconfig:${install_dir}/lib64/pkgconfig" \
        ./configure --host="${host}" --prefix="${install_dir}" --enable-static --enable-shared=no \
            --with-crypto=openssl --with-libssl-prefix="${install_dir}" \
            --disable-examples-build;
    make -j "$(nproc)";
    make install;

    _copy_license COPYING libssh2;
}

compile_nghttp2() {
    echo "Compiling nghttp2, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github nghttp2/nghttp2 "${NGHTTP2_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    autoreconf -i --force
    PKG_CONFIG="pkg-config --static --with-path=${install_dir}/lib/pkgconfig:${install_dir}/lib64/pkgconfig" \
        ./configure --host="${host}" --prefix="${install_dir}" --enable-static --enable-http3 \
            --enable-lib-only --enable-shared=no;
    make -j "$(nproc)";
    make install;

    _copy_license COPYING nghttp2;
}

compile_ngtcp2() {
    if [ "${TLS_LIB}" = "openssl" ]; then
        return
    fi
    echo "Compiling ngtcp2, Arch: ${arch}" | tee "${result_dir}/running"

    local url
    change_dir;

    url_from_github ngtcp2/ngtcp2 "${NGTCP2_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    make clean || true;

    autoreconf -i --force
    CC=${host}-gcc CXX=${host}-g++ CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}" \
    LDFLAGS="--static -static -Wl,--no-as-needed -L${lib_dir}" LIBS="-lpthread" \
    LD_LIBRARY_PATH="-L${lib_dir}" PKG_CONFIG_PATH="${lib_dir}/pkgconfig" \
        ./configure --host="${host}" --prefix="${install_dir}" --enable-static --with-openssl="${install_dir}" \
            --with-libnghttp3="${install_dir}" --enable-lib-only --enable-shared=no;
    make -j "$(nproc)";
    make install;

    _copy_license COPYING ngtcp2;
}

compile_nghttp3() {
    echo "Compiling nghttp3, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github ngtcp2/nghttp3 "${NGHTTP3_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    autoreconf -i --force
    PKG_CONFIG="pkg-config --static --with-path=${install_dir}/lib/pkgconfig:${install_dir}/lib64/pkgconfig" \
        ./configure --host="${host}" --prefix="${install_dir}" --enable-static --enable-shared=no --enable-lib-only;
    make -j "$(nproc)";
    make install;

    _copy_license COPYING nghttp3;
}

compile_brotli() {
    echo "Compiling brotli, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github google/brotli "${BROTLI_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    mkdir -p out
    cd out/

    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${install_dir}" -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_SYSTEM_PROCESSOR="${arch_build}" -DCMAKE_C_COMPILER="${host}-gcc" ..;
    cmake --build . --config Release --target install;

    _copy_license ../LICENSE brotli;
}

compile_zstd() {
    echo "Compiling zstd, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github facebook/zstd "${ZSTD_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    mkdir -p build/cmake/out/
    cd build/cmake/out/


    CC=${host}-gcc cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${install_dir}" -DCMAKE_SYSTEM_PROCESSOR="${arch_build}" -DCMAKE_C_COMPILER="${host}-gcc" \
        -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF ..;
    CC=${host}-gcc cmake --build . --config Release --target install;

    _copy_license ../../../LICENSE zstd
    if [ ! -f "${install_dir}/lib/libzstd.a" ]; then cp -f lib/libzstd.a "${install_dir}/lib/libzstd.a"; fi
}

compile_trurl() {
    case "${ENABLE_TRURL}" in
        true|1|yes|on|y|Y)
            echo ;;
        *)
            return ;;
    esac

    echo "Compiling trurl, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    url_from_github curl/trurl "${TRURL_TAG}"
    url="${URL}"
    download_and_extract "${url}"

    export PATH=${install_dir}/bin:$PATH

    LDFLAGS="-static -Wl,-s ${LDFLAGS}" make install_dir="${install_dir}";
    make install;

    _copy_license LICENSES/curl.txt trurl;
}

curl_config() {
    echo "Configuring curl, Arch: ${arch}" | tee "${result_dir}/running"
    local with_openssl_quic

    # --with-openssl-quic and --with-ngtcp2 are mutually exclusive
    with_openssl_quic=""
    if [ "${TLS_LIB}" = "openssl" ]; then
        with_openssl_quic="--with-openssl-quic"
    else
        with_openssl_quic="--with-ngtcp2"
    fi

    if [ ! -f configure ]; then
        autoreconf -fi;
    fi

    make clean || true
    #https://github.com/curl/curl/issues/14879
    rm src/tool_ca_embed.c
    #custom_flags_set
    CC=${host}-gcc CXX=${host}-g++ CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}" \
    LDFLAGS="--static -static -Wl,--no-as-needed -L${lib_dir}" LIBS="-lpthread" \
    LD_LIBRARY_PATH="-L${lib_dir}" PKG_CONFIG_PATH="${lib_dir}/pkgconfig" \
    ./configure \
    --build="x86_64-alpine-linux-musl" \
    --host="${host}" \
    --target="${host}" \
    --prefix="${install_dir}" \
    --enable-static --disable-shared \
    --with-openssl "${with_openssl_quic}" --with-brotli --with-zstd \
    --with-nghttp2 --with-nghttp3 \
    --with-libidn2 --with-libssh2 \
    --enable-hsts --enable-mime --enable-cookies \
    --enable-http-auth --enable-manual \
    --enable-proxy --enable-file --enable-http \
    --enable-ftp --enable-telnet --enable-tftp \
    --enable-pop3 --enable-imap --enable-smtp \
    --enable-gopher --enable-mqtt \
    --enable-doh --enable-dateparse --enable-verbose \
    --enable-alt-svc --enable-websockets \
    --enable-ipv6 --enable-unix-sockets --enable-socketpair \
    --enable-headers-api --enable-versioned-symbols \
    --enable-threaded-resolver --enable-optimize --enable-pthreads \
    --enable-warnings --enable-werror \
    --enable-curldebug --enable-dict --enable-netrc \
    --enable-bearer-auth --enable-tls-srp --enable-dnsshuffle \
    --enable-get-easy-options --enable-progress-meter \
    --enable-ares --disable-ldap --disable-ldaps \
    --with-ca-embed=/root/src/curl-ca-bundle.crt \
    --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
    --with-ca-path=/etc/ssl/certs \
    --with-ca-fallback
}

compile_curl() {
    echo "Compiling curl, Arch: ${arch}" | tee "${result_dir}/running"
    local url
    change_dir;

    if [ "${CURL_TAG}" = "dev" ]; then
        if [ ! -d "curl-dev" ]; then
            git clone --depth 1 https://github.com/curl/curl.git curl-dev;
        fi
        cd curl-dev;
        make clean || true;
    else
        url_from_github curl/curl "${CURL_TAG}";
        url="${URL}";
        download_and_extract "${url}";
        if [ ! -f src/.checksrc ]; then echo "enable STDERR" > src/.checksrc; fi
        [ -z "${CURL_TAG}" ] && CURL_TAG=$(echo "${SOURCE_DIR}" | cut -d'-' -f 2);
        make clean || true;
    fi

    curl_config;
    custom_flags_set
    if [ "${arch}" = "armv5te" ] || [ "${arch}" = "armv7l" ] || [ "${arch}" = "armv7" ] || \
    [ "${arch}" = "mipsel" ] || [ "${arch}" = "mips" ] || [ "${arch}" = "powerpc" ] || \
    [ "${arch}" = "i686" ]; then
        # add -Wno-cast-align to avoid error alignment from 4 to 8
        # add addition brotli libs
        # https://lists.privoxy.org/pipermail/privoxy-devel/2021-January/000443.html
        make -j "$(nproc)" LDFLAGS="-static -Wl,-s ${LDFLAGS}" CFLAGS="-Wno-cast-align ${CFLAGS}" LIBS="${LIBS} -lbrotlicommon -lbrotlienc";
    else
        make -j "$(nproc)" LDFLAGS="-static -all-static -Wl,-s ${LDFLAGS}" LIBS="${LIBS} -lbrotlicommon -lbrotlienc";
    fi

    _copy_license COPYING curl;
    make install;
}

compile_libs() {
    echo "Compiling all libs for ${arch}"

    compile_tls;
    compile_zlib;
    compile_zstd;
    compile_libunistring;
    compile_libidn2;
    compile_libpsl;
    compile_ares;
    compile_libssh2;
    compile_nghttp3;
    compile_ngtcp2;
    compile_nghttp2;
    compile_brotli;
}

compile() {
    echo "Compiling cURL for ${arch}"
    compile_curl;
    compile_trurl;
}

#alpine_init
clean_folder
#compile_libs
compile
