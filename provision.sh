#!/bin/bash

set -x

export DEBIAN_FRONTEND=noninteractive
export APTGET="apt-get -o Dpkg::Options::=--force-confnew --force-yes -fuy"
export KEYSTONE_AUTH_TOKEN=moumou
export KEYSTONE_ADM_PASS=secret
export KEYSTONE_ENDPOINT_IP=127.0.0.1
export KEYSTONE_REGION=RegionOne
export KEYSTONE_SQL_USER=keystone
export KEYSTONE_SQL_PASS=keystone

gplhost_sources() {
    cat > /etc/apt/sources.list.d/grizzly_gplhost.list <<EOF
deb http://ftparchive.gplhost.com/debian grizzly main
deb http://ftparchive.gplhost.com/debian grizzly-backports main
EOF
    test -f /tmp/gplhost-archive-keyring.deb || wget -O /tmp/gplhost-archive-keyring.deb http://ftparchive.gplhost.com/debian/pool/squeeze/main/g/gplhost-archive-keyring/gplhost-archive-keyring_20100926-1_all.deb
    dpkg -i /tmp/gplhost-archive-keyring.deb
}

make_it_faster () {
    cat > /etc/apt/apt.conf.d/99perso <<EOF
Acquire::PDifss "false";
Acquire::Languages "none";
EOF

    apt-get -y update

    $APTGET install eatmydata

    cat > /etc/profile.d/eatmydata.sh <<EOF
export LD_PRELOAD=/usr/lib/libeatmydata/libeatmydata.so
EOF
    . /etc/profile.d/eatmydata.sh
}

install_mysql_server () {
    echo "mysql-server-5.5 mysql-server/root_password password ${MYSQL_PASSWORD}
mysql-server-5.5 mysql-server/root_password seen true
mysql-server-5.5 mysql-server/root_password_again password ${MYSQL_PASSWORD}
mysql-server-5.5 mysql-server/root_password_again seen true
" | debconf-set-selections
    $APTGET install -y mysql-server
}

set_dbconfig_conf () {
    local PKG_NAME SQL_PASS
    PKG_NAME=${1}
    SQL_USER=${2}
    SQL_PASS=${3}
    DB_NAME=${4}
    echo "dbc_install='true'
dbc_upgrade='true'
dbc_remove=''
dbc_dbtype='mysql'
dbc_dbuser='"${SQL_USER}"'
dbc_dbpass='"${SQL_PASS}"'
dbc_dbserver=''
dbc_dbport=''
dbc_dbname='${DB_NAME}'
dbc_dbadmin='root'
dbc_basepath=''
dbc_ssl=''
dbc_authmethod_admin=''
dbc_authmethod_user=''" >/etc/dbconfig-common/${PKG_NAME}.conf
    echo "${PKG_NAME} dbconfig-common/dbconfig-install boolean true
${PKG_NAME} dbconfig-common/dbconfig-install seen true
${PKG_NAME} dbconfig-common/dbconfig-reinstall boolean true
${PKG_NAME} dbconfig-common/dbconfig-reinstall seen true
${PKG_NAME} dbconfig-common/dbconfig-upgrade boolean true
${PKG_NAME} dbconfig-common/dbconfig-upgrade seen true
${PKG_NAME} dbconfig-common/database-type select mysql
${PKG_NAME} dbconfig-common/database-type seen true
${PKG_NAME} dbconfig-common/mysql/admin-user string root
${PKG_NAME} dbconfig-common/mysql/admin-user seen true
${PKG_NAME} dbconfig-common/mysql/admin-pass string ${MYSQL_PASSWORD}
${PKG_NAME} dbconfig-common/mysql/admin-pass seen true
" | debconf-set-selections
}


install_keystone () {
	echo "keystone keystone/configure_db boolean true
keystone keystone/configure_db seen true
keystone keystone/auth-token password ${KEYSTONE_AUTH_TOKEN}
keystone keystone/auth-token seen true
keystone keystone/create-admin-tenant boolean true
keystone keystone/create-admin-tenant seen true
keystone keystone/admin-user string admin
keystone keystone/admin-user seen true
keystone keystone/admin-email string root@localhost
keystone keystone/admin-email seen true
keystone keystone/admin-password password ${KEYSTONE_ADM_PASS}
keystone keystone/admin-password seen true
keystone keystone/admin-password-confirm password ${KEYSTONE_ADM_PASS}
keystone keystone/admin-password-confirm seen true
keystone keystone/admin-role-name string admin
keystone keystone/admin-role-name seen true
keystone keystone/admin-tenant-name string admin
keystone keystone/admin-tenant-name seen true
keystone keystone/register-endpoint boolean true
keystone keystone/register-endpoint seen true
keystone keystone/endpoint-ip string ${KEYSTONE_ENDPOINT_IP}
keystone keystone/endpoint-ip seen true
keystone keystone/region-name string ${KEYSTONE_REGION}
keystone keystone/region-name seen true
" | debconf-set-selections
	set_dbconfig_conf keystone ${KEYSTONE_SQL_USER} ${KEYSTONE_SQL_PASS} keystone
	DEBIAN_FRONTEND=noninteractive $APTGET install -y keystone

    # Ensure we're using the SQL driver for tokens
    awk '/\[token\]/ { print; print "driver = keystone.token.backends.sql.Token"; next }1' /etc/keystone/keystone.conf > /tmp/ks
    mv /tmp/ks /etc/keystone/keystone.conf
    chown keystone:keystone /etc/keystone/keystone.conf
}

write_openrc () {
    cat > /root/openrc.sh <<EOF
export OS_USERNAME=admin
export OS_TENANT_NAME=admin
export OS_REGION=${KEYSTONE_REGION}
export OS_AUTH_URL=http://${KEYSTONE_ENDPOINT_IP}:5000/v2.0
export OS_PASSWORD=${KEYSTONE_ADM_PASS}
EOF
}

write_json () {
    cat > /root/auth.json <<EOF
{"auth":{"tenantName": "admin", "passwordCredentials":{"username": "admin", "password": "${KEYSTONE_ADM_PASS}"}}}
EOF
}

install_wsgi_stuff () {
    ${APTGET} install apache2 libapache2-mod-wsgi nginx-light uwsgi gunicorn facter git

    git clone --depth 1 -b stable/grizzly git://github.com/openstack/keystone.git /tmp/keystone
    mkdir -p /var/www/cgi-bin/keystone
    cp /tmp/keystone/httpd/keystone.py /var/www/cgi-bin/keystone/main
    cp /tmp/keystone/httpd/keystone.py /var/www/cgi-bin/keystone/admin
}

stop_all () {
    service keystone stop
    service apache2 stop
    service nginx stop
    service uwsgi stop
    service gunicorn stop
}

setup_keystone_apache_mod_wsgi () {
    cat > /etc/apache2/sites-available/keystone <<EOF
<VirtualHost *:5000>
    WSGIDaemonProcess keystone-main user=keystone group=keystone processes=$(facter processorcount) threads=2
    WSGIScriptAlias / /var/www/cgi-bin/keystone/main

    <Directory /var/www/cgi-bin/keystone>
        WSGIProcessGroup keystone-main
        WSGIApplicationGroup %{GLOBAL}
        Order deny,allow
        Allow from all
    </Directory>
</VirtualHost>

NameVirtualHost *:5000
Listen 5000

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin user=keystone group=keystone processes=$(facter processorcount) threads=2
    WSGIScriptAlias / /var/www/cgi-bin/keystone/admin

    <Directory /var/www/cgi-bin/keystone>
        WSGIProcessGroup keystone-admin
        WSGIApplicationGroup %{GLOBAL}
        Order deny,allow
        Allow from all
    </Directory>
</VirtualHost>

NameVirtualHost *:35357
Listen 35357
EOF
    a2ensite keystone
    service apache2 restart
}

test_keystone () {
    local TEST_NAME
    TEST_NAME=${1}
    . /root/openrc.sh

    stop_all
    service ${TEST_NAME} start
    sleep 10
    ab -n 1000 -c 20 -p /root/auth.json -T "application/json" http://127.0.0.1:5000/v2.0/tokens | tee /tmp/testresult_${TEST_NAME}
}

gplhost_sources
make_it_faster
install_mysql_server
install_keystone
write_openrc
write_json
install_wsgi_stuff
stop_all
setup_keystone_apache_mod_wsgi
test_keystone keystone
test_keystone apache2
