#!/bin/bash -e

# A POSIX variable
OPTIND=1 # Reset in case getopts has been used previously in the shell.

while getopts "a:v:q:u:d:t:" opt; do
    case "$opt" in
    a)  ARCH=$OPTARG
        ;;
    v)  VERSION=$OPTARG
        ;;
    q)  QEMU_ARCH=$OPTARG
        ;;
    u)  QEMU_VER=$OPTARG
        ;;
    d)  DOCKER_REPO=$OPTARG
        ;;
    t)  TAG_ARCH=$OPTARG
        ;;
    esac
done

thisTarBase="ubuntu-$VERSION-server-cloudimg-$ARCH"
thisTar="$thisTarBase-root.tar.xz"
baseUrl="https://cloud-images.ubuntu.com/releases/$VERSION"


# install qemu-user-static
if [ -n "${QEMU_ARCH}" ]; then
    root_dir=$(pwd)
    if [ ! -f x86_64_qemu-${QEMU_ARCH}-static.tar.gz ]; then
        cd /tmp
        wget --content-disposition http://ftp.de.debian.org/debian/pool/main/q/qemu/qemu-user-static_${QEMU_VER}_amd64.deb
        dpkg-deb -R qemu-user-static_*.deb releases
        cd releases/usr/bin
        for file in *; do tar -czf $root_dir/x86_64_$file.tar.gz $file; done
        cd $root_dir
    fi
    tar -xvf x86_64_qemu-${QEMU_ARCH}-static.tar.gz -C $ROOTFS/usr/bin/
fi


# get the image
if \
	wget -q --spider "$baseUrl/release" \
	&& wget -q --spider "$baseUrl/release/$thisTar" \
	; then
		baseUrl+='/release'
fi
wget -qN "$baseUrl/"{{MD5,SHA{1,256}}SUMS{,.gpg},"$thisTarBase.manifest",'unpacked/build-info.txt'} || true
wget -N "$baseUrl/$thisTar"

# check checksum
if [ -f SHA256SUMS ]; then
	sha256sum="$(sha256sum "$thisTar" | cut -d' ' -f1)"
	if ! grep -q "$sha256sum" SHA256SUMS; then
		echo >&2 "error: '$thisTar' has invalid SHA256"
		exit 1
	fi
fi

cat > Dockerfile <<-EOF
	FROM scratch
	ADD $thisTar /
	ENV ARCH=${ARCH} UBUNTU_SUITE=${VERSION} DOCKER_REPO=${DOCKER_REPO}
EOF

# add qemu-user-static binary
if [ -n "${QEMU_ARCH}" ]; then
    cat >> Dockerfile <<EOF

# Add qemu-user-static binary for amd64 builders
ADD x86_64_qemu-${QEMU_ARCH}-static.tar.gz /usr/bin
EOF
fi

cat >> Dockerfile <<-EOF
	# a few minor docker-specific tweaks
	# see https://github.com/docker/docker/blob/master/contrib/mkimage/debootstrap
	RUN echo '#!/bin/sh' > /usr/sbin/policy-rc.d \\
		&& echo 'exit 101' >> /usr/sbin/policy-rc.d \\
		&& chmod +x /usr/sbin/policy-rc.d \\
		&& dpkg-divert --local --rename --add /sbin/initctl \\
		&& cp -a /usr/sbin/policy-rc.d /sbin/initctl \\
		&& sed -i 's/^exit.*/exit 0/' /sbin/initctl \\
		&& echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/docker-apt-speedup \\
		&& echo 'DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' > /etc/apt/apt.conf.d/docker-clean \\
		&& echo 'APT::Update::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' >> /etc/apt/apt.conf.d/docker-clean \\
		&& echo 'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";' >> /etc/apt/apt.conf.d/docker-clean \\
		&& echo 'Acquire::Languages "none";' > /etc/apt/apt.conf.d/docker-no-languages \\
		&& echo 'Acquire::GzipIndexes "true"; Acquire::CompressionTypes::Order:: "gz";' > /etc/apt/apt.conf.d/docker-gzip-indexes

	# enable the universe
	RUN sed -i 's/^#\s*\(deb.*universe\)$/\1/g' /etc/apt/sources.list

	# overwrite this with 'CMD []' in a dependent Dockerfile
	CMD ["/bin/bash"]
EOF
