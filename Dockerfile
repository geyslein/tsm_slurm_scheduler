FROM centos:7.9.2009 as base

ENV PATH "/root/.pyenv/shims:/root/.pyenv/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin"

EXPOSE 6817 6818 6819 6820 3306

# Install common YUM dependency packages
# The IUS repo install epel-release as a dependency while also providing a newer version of Git
RUN set -ex \
    && yum makecache fast \
    && yum -y update \
    && yum -y install https://repo.ius.io/ius-release-el7.rpm \
    && yum -y install \
        autoconf \
        bash-completion \
        bzip2 \
        bzip2-devel \
        curl \
        unzip \
        file \
        iproute \
        gcc \
        gcc-c++ \
        gdbm-devel \
        git236 \
        glibc-devel \
        gmp-devel \
        libffi-devel \
        libGL-devel \
        libX11-devel \
        make \
        mariadb-server \
        mariadb-devel \
        munge \
        munge-devel \
        ncurses-devel \
        patch \
        perl-core \
        pkgconfig \
        psmisc \
        readline-devel \
        sqlite-devel \
        tcl-devel \
        tix-devel \
        tk \
        tk-devel \
        supervisor \
        wget \
        which \
        vim-enhanced \
        xz-devel \
        zlib-devel \
        http-parser-devel \
        json-c-devel \
        libjwt-devel \
        libyaml-devel \
    && yum clean all \
    && rm -rf /var/cache/yum

# Add Tini
ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini

# Install OpenSSL1.1.1
# See PEP 644: https://www.python.org/dev/peps/pep-0644/
ARG OPENSSL_VERSION="1.1.1t"
RUN set -ex \
    && wget --quiet https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz \
    && tar xzf openssl-${OPENSSL_VERSION}.tar.gz \
    && pushd openssl-${OPENSSL_VERSION} \
    && ./config --prefix=/opt/openssl --openssldir=/etc/ssl \
    && make \
    && make test \
    && make install \
    && echo "/opt/openssl/lib" >> /etc/ld.so.conf.d/openssl.conf \
    && ldconfig \
    && popd \
    && rm -rf openssl-${OPENSSL_VERSION}.tar.gz


FROM base as build

# currently the latest version on EVE
ARG PYTHON_VERSION="3.8.6"

RUN set -ex \
    && wget https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz \
    && tar xvf Python-${PYTHON_VERSION}.tgz \
    && pushd Python-${PYTHON_VERSION} \
    && ./configure --enable-optimizations --with-ensurepip=install \
    && make altinstall \
    && popd \
    && rm -rf Python-${PYTHON_VERSION}

## Install supported Python versions and install dependencies.
## Set the default global to the latest supported version.
## Use pyenv inside the container to switch between Python versions.
#ARG PYTHON_VERSIONS="3.9 3.10"
#RUN set -ex \
#    && curl https://pyenv.run | bash \
#    && echo "eval \"\$(pyenv init --path)\"" >> "${HOME}/.bashrc" \
#    && echo "eval \"\$(pyenv init -)\"" >> "${HOME}/.bashrc" \
#    && source "${HOME}/.bashrc" \
#    && pyenv update \
#
#FROM build as foo
#RUN set -ex \
#    && for python_version in ${PYTHON_VERSIONS}; \
#        do \
#            pyenv install $python_version; \
#            pyenv global $python_version; \
#            pip install Cython pytest; \
#        done

# Compile, build and install Slurm from Git source
ARG SLURM_TAG=slurm-21-08-8-2
ARG JOBS=4
RUN set -ex \
    && git clone -b ${SLURM_TAG} --single-branch --depth=1 https://github.com/SchedMD/slurm.git \
    && pushd slurm \
    && ./configure --prefix=/usr --sysconfdir=/etc/slurm --enable-slurmrestd \
        --with-mysql_config=/usr/bin --libdir=/usr/lib64 \
    && sed -e 's|#!/usr/bin/env python3|#!/usr/bin/python|' -i doc/html/shtml2html.py \
    && make -j ${JOBS} install \
    && install -D -m644 etc/cgroup.conf.example /etc/slurm/cgroup.conf.example \
    && install -D -m644 etc/slurm.conf.example /etc/slurm/slurm.conf.example \
    && install -D -m600 etc/slurmdbd.conf.example /etc/slurm/slurmdbd.conf.example \
    && install -D -m644 contribs/slurm_completion_help/slurm_completion.sh /etc/profile.d/slurm_completion.sh \
    && popd \
    && rm -rf slurm \
    && groupadd -r slurm  \
    && useradd -r -g slurm slurm \
    && mkdir -p /etc/sysconfig/slurm \
        /var/spool/slurmd \
        /var/spool/slurmctld \
        /var/log/slurm \
        /var/run/slurm \
    && chown -R slurm:slurm /var/spool/slurmd \
        /var/spool/slurmctld \
        /var/log/slurm \
        /var/run/slurm \
    && /sbin/create-munge-key

RUN dd if=/dev/random of=/etc/slurm/jwt_hs256.key bs=32 count=1 \
    && chmod 600 /etc/slurm/jwt_hs256.key && chown slurm.slurm /etc/slurm/jwt_hs256.key

COPY --chown=slurm files/slurm/slurm.conf files/slurm/gres.conf files/slurm/slurmdbd.conf /etc/slurm/
COPY files/supervisord.conf /etc/

RUN chmod 0600 /etc/slurm/slurmdbd.conf

FROM build as dist

# Mark externally mounted volumes
VOLUME ["/var/lib/mysql", "/var/lib/slurmd", "/var/spool/slurm", "/var/log/slurm"]

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]
