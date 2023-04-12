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

# Compile, build and install Slurm from Git source
ARG SLURM_TAG=slurm-22-05-8-1
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

COPY --chown=slurm \
    files/slurm/slurm.conf \
    files/slurm/slurmdbd.conf \
    files/slurm/cgroup.conf \
    /etc/slurm/

COPY files/supervisord.conf /etc/

RUN chmod 0600 /etc/slurm/slurmdbd.conf

FROM build as dist

# Mark externally mounted volumes
VOLUME ["/var/lib/mysql", "/var/lib/slurmd", "/var/spool/slurm", "/var/log/slurm"]

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]

FROM dist as foo

## need for download instant client
#RUN set -ex \
#    && yum makecache fast \
#    && yum -y install  \
#        curl  \
#        unzip \
#    && rm -rf /var/cache/yum
#
## fetch oracle instant client
#RUN set -ex \
#    && curl \
#        "https://download.oracle.com/otn_software/linux/instantclient/213000/instantclient-basiclite-linux.x64-21.3.0.0.0.zip" \
#        > /tmp/instantclient-basiclite-linux.x64.zip \
#    && unzip /tmp/instantclient-basiclite-linux.x64.zip -d /usr/lib/oracle
#
#RUN echo "NAMES.DIRECTORY_PATH = ( TNSNAMES, LDAP )"          >> /usr/lib/oracle/instantclient_21_3/network/admin/sqlnet.ora \
#    && echo "NAMES.DEFAULT_DOMAIN = UFZ.DE"                      >> /usr/lib/oracle/instantclient_21_3/network/admin/sqlnet.ora \
#    && echo "NAMES.LDAP_CONN_TIMEOUT = 1"                        >> /usr/lib/oracle/instantclient_21_3/network/admin/sqlnet.ora \
#    && echo "DIRECTORY_SERVERS = (tnsnames.intranet.ufz.de:389)" >> /usr/lib/oracle/instantclient_21_3/network/admin/ldap.ora \
#    && echo "DEFAULT_ADMIN_CONTEXT = \"ou=oracle,dc=ufz,dc=de\"" >> /usr/lib/oracle/instantclient_21_3/network/admin/ldap.ora \
#    && echo "DIRECTORY_SERVER_TYPE = OID"                        >> /usr/lib/oracle/instantclient_21_3/network/admin/ldap.ora
#
## python requirements
#COPY src/tsm-extractor/src/requirements.txt /tmp/requirements.txt
#RUN set -ex \
#    && pip3.9 install --upgrade pip \
#    && pip3.9 install \
#        --no-cache-dir \
#        --no-warn-script-location  \
#        -r /tmp/requirements.txt
#
#
#RUN echo /usr/lib/oracle/instantclient_21_3 \
#      > /etc/ld.so.conf.d/oracle-instantclient.conf  \
#    && ldconfig
#
#
## make /work (like in eve) and make it read and writeable
#RUN mkdir -p /work/sontsm && chmod -R a+rwx /work
#
## add user sontsm (same user as we have on EVE)
#RUN useradd --uid 1000 -m sontsm
#USER sontsm
#WORKDIR /home/sontsm
#COPY src .
#
## The entrypoint.sh needs to be run as root, but the
## webserver and invoked comands should be run as `sontsm`
## (our eve user). Actually this is not quite easy, because
## changing the user with `su` either requires a script
## (current case) or a single command (with -c). In the
## latter case all given parameters will be interpreted
## as params for `su`, instead as for the python script.
## Thats the reason we go for the first case and use a
## wrapper script (`pipe.sh`), which replace itself with
## the next following command (`python ...`) and all its
## parameters by using bash magic (`exec "$@"`).
#USER root
#COPY pipe.sh /pipe.sh
#
#ENTRYPOINT [ \
#    "/tini", "--", \
#    "/usr/local/bin/docker-entrypoint.sh", \
#    "su", "sontsm", "/pipe.sh", "--", \
#    "python3.9", "webapi/server.py" \
#    ]
#
#CMD ["--mqtt-broker", "None"]
FROM foo as devel

RUN set -ex \
    && echo "alias ls='ls --color=auto'"         >> "/root/.bashrc" \
    && echo "alias ll='ls --color=auto -lAhF'"   >> "/root/.bashrc" \
    && echo "alias ..='cd ..'"                  >> "/root/.bashrc" \
    && echo "set -o vi"                         >> "/root/.bashrc"
