#!/bin/bash
############################
# LME Deploy Script        #
############################
# This script configures a host for LME including generating certificates and populating configuration files.
DATE="$(date '+%Y-%m-%d-%H:%M:%S')"

#prompt for y/n
prompt() {
  if [ -z "$1" ];
  then
    str="Are you sure?"
  else
    str=$1
  fi

  while true
  do
   read -r -p "$str? [Y/n] " input
   
   case $input in
       [yY][eE][sS]|[yY])
       return 0 #true
   break
   ;;
       [nN][oO]|[nN])
       return 1 #false
   break
          ;;
       *)
   echo "Invalid input..."
   ;;
   esac
  done
}


function customlogstashconf() {
  #add option for custom logstash config
  CUSTOM_LOGSTASH_CONF=/opt/lme/Chapter\ 3\ Files/logstash_custom.conf
  if test -f "$CUSTOM_LOGSTASH_CONF"; then
    echo -e "\e[32m[X]\e[0m Custom logstash config exists, Not creating"
  else
    echo -e "\e[32m[X]\e[0m Creating custom logstash conf"
    echo "#custom logstash configuration file" >>/opt/lme/Chapter\ 3\ Files/logstash_custom.conf
  fi
}

function generatepasswords() {

  elastic_user_pass=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
  kibana_system_pass=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
  logstash_system_pass=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
  logstash_writer=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
  update_user_pass=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
  kibanakey=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 42 | head -n 1)

  echo -e "\e[32m[X]\e[0m Updating logstash configuration with logstash writer"
  cp /opt/lme/Chapter\ 3\ Files/logstash.conf /opt/lme/Chapter\ 3\ Files/logstash.edited.conf
  sed -i "s/insertlogstashwriterpasswordhere/$logstash_writer/g" /opt/lme/Chapter\ 3\ Files/logstash.edited.conf
}

function setroles() {
  echo -e "\n\e[32m[X]\e[0m Setting logstash writer role"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/role/logstash_writer" -H 'Content-Type: application/json' -d'
{
  "cluster": ["manage_index_templates", "monitor", "manage_ilm", "manage_pipeline"], 
  "indices": [
    {
      "names": [ "logstash-*, ecs-logstash-*","winlogbeat-*" ], 
      "privileges": ["write","create","create_index","manage","manage_ilm"]  
    }
  ]
}
'

  #create role, Only needs kibana perms so the other data is just falsified.
  echo -e "\n\e[32m[X]\e[0m Setting dashboard update role"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/role/dashboard_update" -H 'Content-Type: application/json' -d'
{
  "cluster":[],
  "indices":[],
  "applications":[{
    "application":"kibana-.kibana",
  "privileges":[
  "feature_canvas.all",
  "feature_savedObjectsManagement.all",
  "feature_indexPatterns.all",
  "feature_dashboard.all",
  "feature_visualize.all"],
  "resources":["*"]}],
  "run_as":[],
  "metadata":{},
  "transient_metadata":{"enabled":true}}
'
}

function setpasswords() {
  temp="temp"
  #override temp password if overwriting an old docker container
  if [ -v OLD_ELASTIC_PASS ];
  then
    temp=$OLD_ELASTIC_PASS
  fi

  echo -e "\e[32m[X]\e[0m Waiting for Elasticsearch to be ready"
  max_attempts=180
  attempt=0
  while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' --cacert certs/root-ca.crt --user elastic:${temp} https://127.0.0.1:9200)" != "200" ]]; do
    printf '.'
    sleep 1
    ((attempt++))
    if ((attempt > max_attempts)); then
        echo "Elasticsearch is not responding after $max_attempts attempts - exiting."
        exit 1
    fi
  done
  echo "Elasticsearch is up and running."

  echo -e "\e[32m[X]\e[0m Setting elastic user password"
  curl --cacert certs/root-ca.crt --user elastic:${temp} -X POST "https://127.0.0.1:9200/_security/user/elastic/_password" -H 'Content-Type: application/json' -d' { "password" : "'"$elastic_user_pass"'"} '

  echo -e "\n\e[32m[X]\e[0m Setting kibana system password"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/user/kibana_system/_password" -H 'Content-Type: application/json' -d' { "password" : "'"$kibana_system_pass"'"} '

  echo -e "\n\e[32m[X]\e[0m Setting logstash system password"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/user/logstash_system/_password" -H 'Content-Type: application/json' -d' { "password" : "'"$logstash_system_pass"'"} '

  setroles

  echo -e "\n\e[32m[X]\e[0m Creating logstash writer user"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/user/logstash_writer" -H 'Content-Type: application/json' -d'
{
  "password" : "logstash_writer",
  "roles" : [ "logstash_writer"],
  "full_name" : "Internal Logstash User"
  }
'

  echo -e "\n\e[32m[X]\e[0m Setting logstash writer password"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/user/logstash_writer/_password" -H 'Content-Type: application/json' -d' { "password" : "'"$logstash_writer"'"} '

  echo -e "\n\e[32m[X]\e[0m Creating dashboard update user"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/user/dashboard_update" -H 'Content-Type: application/json' -d'
{
  "password" : "dashboard_update",
  "roles" : [ "dashboard_update"],
  "full_name" : "Internal dashboard update User"
  }
'

  echo -e "\n\e[32m[X]\e[0m Setting dashboard update user password"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X POST "https://127.0.0.1:9200/_security/user/dashboard_update/_password" -H 'Content-Type: application/json' -d' { "password" : "'"$update_user_pass"'"} '
}

function zipfiles() {
  #zip the files to allow the user to download them for the WLB install.
  #copy them to home to start with
  echo -e "\n\e[32m[X]\e[0m Generating files_for_windows zip"

  mkdir -p /tmp/lme
  cp /opt/lme/Chapter\ 3\ Files/winlogbeat.yml /tmp/lme/
  if [ -r /opt/lme/Chapter\ 3\ Files/certs/wlbclient.crt ]; then
    cp /opt/lme/Chapter\ 3\ Files/certs/wlbclient.crt /tmp/lme/
  fi
  if [ -r /opt/lme/Chapter\ 3\ Files/certs/wlbclient.key ]; then
    cp /opt/lme/Chapter\ 3\ Files/certs/wlbclient.key /tmp/lme/
  fi
  cp /opt/lme/Chapter\ 3\ Files/certs/root-ca.crt /tmp/lme/
  sed -i "s/logstash_dns_name/$logstashcn/g" /tmp/lme/winlogbeat.yml
  zip -rmT /opt/lme/files_for_windows.zip /tmp/lme
  # Give global read permissions to new archive for later retrieval
  chmod 664 /opt/lme/files_for_windows.zip

}

function generateCA() {
  echo -e "\e[33m[!]\e[0m Note: Depending on your OpenSSL configuration you may see an error opening a .rnd file into RNG, this will not block the installation"


  #configure certificate authority
  mkdir -p certs

  #make a new key for the root ca
  echo -e "\e[32m[X]\e[0m Making root Certificate Authority"
  openssl genrsa -out certs/root-ca.key 4096

  #make a cert signing request for this key
  openssl req -new -key certs/root-ca.key -out certs/root-ca.csr -sha256 -subj "$CERT_STRING/CN=Swarm"

  #Set openssl so that this root can only sign certs and not sign intermediates
  {
    echo "[root_ca]"
    echo "basicConstraints = critical,CA:TRUE,pathlen:1"
    echo "keyUsage = critical, nonRepudiation, cRLSign, keyCertSign"
    echo "subjectKeyIdentifier=hash"
  } >certs/root-ca.cnf

  #sign the root ca
  echo -e "\e[32m[X]\e[0m Signing root CA"
  openssl x509 -req -days 3650 -in certs/root-ca.csr -signkey certs/root-ca.key -sha256 -out certs/root-ca.crt -extfile certs/root-ca.cnf -extensions root_ca
}

function generatelogstashcert() {
  ##logstash server
  #make a new key for logstash
  echo -e "\e[32m[X]\e[0m Making Logstash certificate"
  openssl genrsa -out certs/logstash.key 4096

  #make a cert signing request for logstash
  openssl req -new -key certs/logstash.key -out certs/logstash.csr -sha256 -subj "$CERT_STRING/CN=$logstashcn"

  #set openssl so that this cert can only perform server auth and cannot sign certs
  {
    echo "[server]"
    echo "authorityKeyIdentifier=keyid,issuer"
    echo "basicConstraints = critical,CA:FALSE"
    echo "extendedKeyUsage=serverAuth"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "subjectAltName = DNS:$logstashcn, IP: $logstaship"
    echo "subjectKeyIdentifier=hash"
  } >certs/logstash.cnf

  #sign the logstash cert
  echo -e "\e[32m[X]\e[0m Signing logstash cert"
  openssl x509 -req -days 750 -in certs/logstash.csr -sha256 -CA certs/root-ca.crt -CAkey certs/root-ca.key -CAcreateserial -out certs/logstash.crt -extfile certs/logstash.cnf -extensions server
  mv certs/logstash.key certs/logstash.key.pem && openssl pkcs8 -in certs/logstash.key.pem -topk8 -nocrypt -out certs/logstash.key
}

function generateclientcert() {
  ##winlogbeat client
  #make a new key for winlogbeat client
  echo -e "\e[32m[X]\e[0m Making Winlogbeat client certificate"
  openssl genrsa -out certs/wlbclient.key 4096

  #make a cert signing request for wlbclient
  openssl req -new -key certs/wlbclient.key -out certs/wlbclient.csr -sha256 -subj "$CERT_STRING/CN=wlbclient"

  #set openssl so that this cert can only perform server auth and cannot sign certs
  {
    echo "[server]"
    echo "authorityKeyIdentifier=keyid,issuer"
    echo "basicConstraints = critical,CA:FALSE"
    echo "extendedKeyUsage=clientAuth"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    #echo "subjectAltName = DNS:localhost, IP:127.0.0.1"
    echo "subjectKeyIdentifier=hash"
  } >certs/wlbclient.cnf

  #sign the wlbclient cert
  echo -e "\e[32m[X]\e[0m Signing wlbclient cert"
  openssl x509 -req -days 750 -in certs/wlbclient.csr -sha256 -CA certs/root-ca.crt -CAkey certs/root-ca.key -CAcreateserial -out certs/wlbclient.crt -extfile certs/wlbclient.cnf -extensions server
}

function generateelasticcert() {
  ##elasticsearch server
  #make a new key for elasticsearch
  echo -e "\e[32m[X]\e[0m Making Elasticsearch certificate"
  openssl genrsa -out certs/elasticsearch.key 4096

  #make a cert signing request for elasticsearch
  openssl req -new -key certs/elasticsearch.key -out certs/elasticsearch.csr -sha256 -subj "$CERT_STRING/CN=elasticsearch"

  #set openssl so that this cert can only perform server auth and cannot sign certs
  {
    echo "[server]"
    echo "authorityKeyIdentifier=keyid,issuer"
    echo "basicConstraints = critical,CA:FALSE"
    echo "extendedKeyUsage=serverAuth,clientAuth"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    #echo "subjectAltName = DNS:elasticsearch, IP:127.0.0.1"
    echo "subjectAltName = DNS:elasticsearch, IP:127.0.0.1, DNS:$logstashcn, IP: $logstaship"
    echo "subjectKeyIdentifier=hash"
  } >certs/elasticsearch.cnf

  #sign the elasticsearchcert
  echo -e "\e[32m[X]\e[0m Sign elasticsearch cert"
  openssl x509 -req -days 750 -in certs/elasticsearch.csr -sha256 -CA certs/root-ca.crt -CAkey certs/root-ca.key -CAcreateserial -out certs/elasticsearch.crt -extfile certs/elasticsearch.cnf -extensions server
  mv certs/elasticsearch.key certs/elasticsearch.key.pem && openssl pkcs8 -in certs/elasticsearch.key.pem -topk8 -nocrypt -out certs/elasticsearch.key
}

function generatekibanacert() {
  ##kibana server
  #make a new key for kibana
  echo -e "\e[32m[X]\e[0m Making Kibana certificate"
  openssl genrsa -out certs/kibana.key 4096

  #make a cert signing request for kibana
  openssl req -new -key certs/kibana.key -out certs/kibana.csr -sha256 -subj "$CERT_STRING/CN=kibana"

  #set openssl so that this cert can only perform server auth and cannot sign certs
  {
    echo "[server]"
    echo "authorityKeyIdentifier=keyid,issuer"
    echo "basicConstraints = critical,CA:FALSE"
    echo "extendedKeyUsage=serverAuth"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    #echo "subjectAltName = DNS:$logstashcn, IP: $logstaship"
    echo "subjectAltName = DNS:kibana, IP:127.0.0.1, DNS:$logstashcn, IP: $logstaship"
    echo "subjectKeyIdentifier=hash"
  } >certs/kibana.cnf

  #sign the kibanacert
  echo -e "\e[32m[X]\e[0m Sign kibana cert"
  openssl x509 -req -days 750 -in certs/kibana.csr -sha256 -CA certs/root-ca.crt -CAkey certs/root-ca.key -CAcreateserial -out certs/kibana.crt -extfile certs/kibana.cnf -extensions server
  mv certs/kibana.key certs/kibana.key.pem && openssl pkcs8 -in certs/kibana.key.pem -topk8 -nocrypt -out certs/kibana.key
}

function populatecerts() {
  #add to docker secrets
  echo -e "\e[32m[X]\e[0m Adding certificates and keys to Docker"

  #ca cert
  docker secret create ca.crt certs/root-ca.crt

  #logstash
  docker secret create logstash.key certs/logstash.key
  docker secret create logstash.crt certs/logstash.crt

  #elasticsearch server
  docker secret create elasticsearch.key certs/elasticsearch.key
  docker secret create elasticsearch.crt certs/elasticsearch.crt

  #kibana server
  docker secret create kibana.key certs/kibana.key
  docker secret create kibana.crt certs/kibana.crt
}

function removecerts() {
  #add to docker secrets
  echo -e "\e[32m[X]\e[0m Removing existing certificates and keys from Docker"

  #ca cert
  docker secret rm ca.crt

  #logstash
  docker secret rm logstash.key
  docker secret rm logstash.crt

  #elasticsearch server
  docker secret rm elasticsearch.key
  docker secret rm elasticsearch.crt

  #kibana server
  docker secret rm kibana.key
  docker secret rm kibana.crt
}

function populatelogstashconfig() {
  #add logstash conf to config
  docker config create logstash.conf logstash.edited.conf

  #add logstash_custom conf to config
  customlogstashconf
  docker config create logstash_custom.conf logstash_custom.conf
}

function configuredocker() {
  sysctl -w vm.max_map_count=262144
  SYSCTL_STATUS=$(grep vm.max_map_count /etc/sysctl.conf)
  if [ "$SYSCTL_STATUS" == "vm.max_map_count=262144" ]; then
    echo "SYSCTL already configured"
  else
    echo "vm.max_map_count=262144" >>/etc/sysctl.conf
  fi

  RAM_COUNT="$(awk '( $1 == "MemAvailable:" ) { print $2/1048576 }' /proc/meminfo | xargs printf "%.*f\n" 0)"
  #Table for ES ram
  if [ "$RAM_COUNT" -lt 8 ]; then
    echo -e "\e[31m[!]\e[0m LME Requires 8GB of RAM Available for use - exiting"
    exit 1
  elif [ "$RAM_COUNT" -ge 8 ] && [ "$RAM_COUNT" -le 16 ]; then
    ES_RAM=$((RAM_COUNT - 4))
  elif [ "$RAM_COUNT" -ge 17 ] && [ "$RAM_COUNT" -le 32 ]; then
    ES_RAM=$((RAM_COUNT - 6))
  elif [ "$RAM_COUNT" -ge 33 ] && [ "$RAM_COUNT" -le 49 ]; then
    ES_RAM=$((RAM_COUNT - 8))
  elif [ "$RAM_COUNT" -ge 50 ]; then
    ES_RAM=31
  else
    echo -e "\e[31m[!]\e[0m Unable to determine RAM - exiting"
    exit 1
  fi

  sed -i "s/ram-count/$ES_RAM/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml

  sed -i "s/insertkibanapasswordhere/$kibana_system_pass/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml

  sed -i "s/kibanakey/$kibanakey/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml

  sed -i "s/insertpublicurlhere/https:\/\/$logstashcn/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
}

function installdocker() {
  echo -e "\e[32m[X]\e[0m Installing Docker"
  curl -fsSL https://get.docker.com -o get-docker.sh >/dev/null
  sh get-docker.sh >/dev/null
}

function initdockerswarm() {
  echo -e "\e[32m[X]\e[0m Configuring Docker swarm"
  docker swarm init --advertise-addr "$logstaship"
  if [ "$?" == 1 ]; then
    echo -e "\e[31m[!]\e[0m Failed to initialize docker swarm (Is $logstaship the correct IP address?) - exiting"
    exit 1
  fi
}

function deploylme() {
  docker stack deploy lme --compose-file /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
}

get_distribution() {
  lsb_dist=""
  # Every system that we officially support has /etc/os-release
  if [ -r /etc/os-release ]; then
    lsb_dist="$(. /etc/os-release && echo "$ID")"
  fi
  # Returning an empty string here should be alright since the
  # case statements don't act unless you provide an actual value
  echo "$lsb_dist"
}


function indexmappingupdate() {
  echo -e "\n\e[32m[X]\e[0m Uploading the LME index template"
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X PUT "https://127.0.0.1:9200/_index_template/lme_template" -H 'Content-Type: application/json' --data "@winlog-index-mapping.json"
}

function pipelineupdate() {
  echo -e "\n\e[32m[X]\e[0m Setting Elastic pipelines"

  #create beats pipeline
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X PUT "https://127.0.0.1:9200/_ingest/pipeline/winlogbeat" -H 'Content-Type: application/json' -d'
{
  "description": "Add geoip info and ingest timestamp",
  "processors": [
    {
      "geoip": {
        "field": "client.ip",
        "target_field": "client.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "source.ip",
        "target_field": "source.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "destination.ip",
        "target_field": "destination.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "server.ip",
        "target_field": "server.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "host.ip",
        "target_field": "host.geo",
        "ignore_missing": true
      }
    },
    { 
      "set": { 
        "field": "event.ingested", 
        "value": "{{_ingest.timestamp}}",
        "ignore_failure": true 
      } 
    }
  ]
}
'
}


function data_retention() {
  #show ext4 disk
  DF_OUTPUT="$(df -h -l -t ext4 --output=source,size /var/lib/docker)"

  #pull dev name
  DISK_DEV="$(echo "$DF_OUTPUT" | grep -Po '[0-9]+G')"

  #pull dev size
  DISK_SIZE_ROUND="${DISK_DEV/G/}"

  #lets do math to get 75% (%80 is low watermark for ES but as curator uses this we want to delete data *before* the disk gets full)
  DISK_80=$((DISK_SIZE_ROUND * 80 / 100))

  echo -e "\e[32m[X]\e[0m We think your main disk is $DISK_DEV"

  if [ "$DISK_80" -lt 30 ]; then
    echo -e "\e[31m[!]\e[0m LME Requires 128GB of space usable for log retention - exiting"
    exit 1
  elif [ "$DISK_80" -ge 90 ] && [ "$DISK_80" -le 179 ]; then
    RETENTION="30"
  elif [ "$DISK_80" -ge 180 ] && [ "$DISK_80" -le 359 ]; then
    RETENTION="90"
  elif [ "$DISK_80" -ge 360 ] && [ "$DISK_80" -le 539 ]; then
    RETENTION="180"
  elif [ "$DISK_80" -ge 540 ] && [ "$DISK_80" -le 719 ]; then
    RETENTION="270"
  elif [ "$DISK_80" -ge 720 ]; then
    RETENTION="365"
  else
    echo -e "\e[31m[!]\e[0m Unable to determine retention policy - exiting"
    exit 1
  fi

  echo -e "\e[32m[X]\e[0m We are assigning $RETENTION days as your retention period for log storage"

  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X PUT "https://127.0.0.1:9200/_ilm/policy/lme_ilm_policy" -H 'Content-Type: application/json' -d'
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_age": "30d",
            "max_primary_shard_size": "50gb"
          }
        }
      },
      "warm": {
        "min_age": "2d",
        "actions": {
          "shrink": {
            "number_of_shards": 1
          }
        }
      },
      "delete": {
        "min_age": "'$RETENTION'd",
        "actions": {
          "delete": {
            "delete_searchable_snapshot": true
          }
        }
      }
    },
    "_meta": {
      "description": "LME ILM policy using the hot and warm phases with a retention of '$RETENTION' days"
    }
  }
}
'
}

function auto_os_updates() {
  lin_ver=$(get_distribution)
  echo "This OS was detected as: $lin_ver"
  if [ "$lin_ver" == "ubuntu" ]; then
    echo -e "\e[32m[X]\e[0m Configuring Auto Updates"
    apt install unattended-upgrades -y -q
    sed -i 's#//Unattended-Upgrade::Automatic-Reboot "false";#Unattended-Upgrade::Automatic-Reboot "true";#g' /etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's#//Unattended-Upgrade::Automatic-Reboot-Time "02:00";#Unattended-Upgrade::Automatic-Reboot-Time "02:00";#g' /etc/apt/apt.conf.d/50unattended-upgrades

    auto_os_updatesfile='/etc/apt/apt.conf.d/20auto-upgrades'
    apt_UPL_0='APT::Periodic::Update-Package-Lists "0";'
    apt_UPL_1='APT::Periodic::Update-Package-Lists "1";'

    apt_UU_0='APT::Periodic::Unattended-Upgrade "0";'
    apt_UU_1='APT::Periodic::Unattended-Upgrade "1";'

    apt_DUP_0='APT::Periodic::Download-Upgradeable-Packages "0";'
    apt_DUP_1='APT::Periodic::Download-Upgradeable-Packages "1";'

    # check if package list is set to 1 or 0 and then make sure its 1 if its not set then set it
    if grep -q -F -e "$apt_UPL_0" -e "$apt_UPL_1" "$auto_os_updatesfile"; then
      sed -i "s#$apt_UPL_0#$apt_UPL_1#g" $auto_os_updatesfile
    else
      echo "$apt_UPL_1" >>$auto_os_updatesfile
    fi

    # check unattended upgrade is set to 1 or 0 and then make sure its 1 if its not set then set it
    if grep -q -F -e "$apt_UU_0" -e "$apt_UU_1" "$auto_os_updatesfile"; then
      sed -i "s#$apt_UU_0#$apt_UU_1#g" $auto_os_updatesfile
    else
      echo "$apt_UU_1" >>$auto_os_updatesfile
    fi

    # check download packages is set to 1 or 0 and then make sure its 1 if its not set then set it
    if grep -q -F -e "$apt_DUP_0" -e "$apt_DUP_1" "$auto_os_updatesfile"; then
      sed -i "s#$apt_DUP_0#$apt_DUP_1#g" $auto_os_updatesfile
    else
      echo "$apt_DUP_1" >>$auto_os_updatesfile
    fi
  else
    echo -e "\e[33m[!]\e[0m Not configuring automatic updates as this OS is not supported"
  fi
}

function configelasticsearch() {
  echo -e "\n\e[32m[X]\e[0m Configuring elasticsearch Replica settings"

  #set future index to always have no replicas
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X PUT "https://127.0.0.1:9200/_template/number_of_replicas" -H 'Content-Type: application/json' -d' {  "template": "*",  "settings": {    "number_of_replicas": 0  }}'
  #set all current indices to have 0 replicas
  curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X PUT "https://127.0.0.1:9200/_all/_settings" -H 'Content-Type: application/json' -d '{"index" : {"number_of_replicas" : 0}}'
}



function writeconfig() {
  echo -e "\n\e[32m[X]\e[0m Writing LME Config"
  #write LME version
  echo "version=1.0" >/opt/lme/lme.conf
  if [ -z "$logstashcn" ]; then
    # $logstashcn is not set - so this function is not called from an initial install
    read -e -p "Enter the Fully Qualified Domain Name (FQDN) of this Linux server: " logstashcn
  fi
  #write elastic hostname
  echo "hostname=$logstashcn" >>/opt/lme/lme.conf

  cp dashboard_update.sh /opt/lme/
  chmod 700 /opt/lme/dashboard_update.sh

  echo -e "\e[32m[X]\e[0m Updating dashboard update configuration with dashboard update user credentials"
  sed -i "s/dashboardupdatepassword/$update_user_pass/g" /opt/lme/dashboard_update.sh

  cp lme_update.sh /opt/lme/
  chmod 700 /opt/lme/lme_update.sh
}

function uploaddashboards() {
  echo -e "\e[32m[X]\e[0m Uploading Kibana dashboards"

  sleep 30 #sleep to make sure port is responsive, it seems to not immediately be available sometimes

  /opt/lme/dashboard_update.sh

  echo ""
}

function zipnewcerts() {
  echo -e "\n\e[32m[X]\e[0m Generating new_client_certificates.zip"
  mkdir -p /tmp/lme
  cp /opt/lme/Chapter\ 3\ Files/certs/wlbclient.crt /tmp/lme/
  cp /opt/lme/Chapter\ 3\ Files/certs/wlbclient.key /tmp/lme/
  cp /opt/lme/Chapter\ 3\ Files/certs/root-ca.crt /tmp/lme/
  zip -rmT /opt/lme/new_client_certificates.zip /tmp/lme
}


function bootstrapindex() {
  if [[ "$(curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -s -o /dev/null -w ''%{http_code}'' https://127.0.0.1:9200/winlogbeat-000001)" != "200" ]]; then
    echo -e "\n\e[32m[X]\e[0m Bootstrapping index alias"
    curl --cacert certs/root-ca.crt --user "elastic:$elastic_user_pass" -X PUT "https://127.0.0.1:9200/winlogbeat-000001" -H 'Content-Type: application/json' -d'
{
  "aliases": {
    "winlogbeat-alias": {
      "is_write_index": true
    }
  }
}
'
  else
    echo -e "\n\e[33m[!]\e[0m Initial index already exists, no need to bootstrap"
  fi
}

function fixreadability() {
 cd /opt/lme/
 chmod -077 -R .

 #some permissions to help with seeing files
 chown root:sudo /opt/lme/
 chmod 750 /opt/lme/
 chmod 644 files_for_windows.zip

 #fix backups
 chown -R 1000:1000 /opt/lme/backups
 chmod -R  go-rwx /opt/lme/backups
 
}

function install() {
  echo -e "Will execute the following intrusive actions:\n\t- apt update/upgrade\n\t- install docker (please uninstall before proceeding, or indicate skipping the install)\n\t- initialize docker swarm (execute \`sudo docker swarm leave --force\`  before proceeding if you are part of a swarm\n\t- automatic os updates via unattened-upgrades)"
  read -e -p "Proceed ([y]es/[n]o):" -i "y" check

  if [ "$check" == "n" ]; then
    return 1
  fi

  echo -e "\e[32m[X]\e[0m Updating OS software"
  apt update && apt upgrade -y

  echo -e "\e[32m[X]\e[0m Installing prerequisites"
  apt install curl zip net-tools -y -q

  if [ -f /var/run/reboot-required ]; then
    echo -e "\e[31m[!]\e[0m A reboot is required in order to proceed with the install."
    echo -e "\e[31m[!]\e[0m Please reboot and re-run this script to finish the install."
    exit 1
  fi

  #enable auto updates if ubuntu
  auto_os_updates

  #move configs
  cp docker-compose-stack.yml docker-compose-stack-live.yml

  #find the IP winlogbeat will use to communicate with the logstash box (on elk)

  #get interface name of default route
  DEFAULT_IF="$(route | grep '^default' | grep -o '[^ ]*$')"

  #get ip of the interface
  EXT_IP="$(/sbin/ifconfig "$DEFAULT_IF" | awk -F ' *|:' '/inet /{print $3}')"

  read -e -p "Enter the IP of this Linux server: " -i "$EXT_IP" logstaship

  read -e -p "Enter the Fully Qualified Domain Name (FQDN) of this Linux server. This needs to be resolvable from the Windows Event Collector: " logstashcn
  echo -e "\e[32m[X]\e[0m Configuring winlogbeat config and certificates to use $logstaship as the IP and $logstashcn as the DNS"

  read -e -p "This script will use self signed certificates for communication and encryption. Do you want to continue with self signed certificates? ([y]es/[n]o): " -i "y" selfsignedyn
  read -e -p "Skip Docker Install? ([y]es/[n]o): " -i "n" skipdinstall
  read -e -p "Do you have an old elastic user password? ([y]es/[n]o): " -i "n" old_elastic_user_pass


  if [ "$old_elastic_user_pass" == "y" ]; then
    res= false
    while [ ! $res ];do
      read -e -p "PASSWORD: " OLD_ELASTIC_PASS 
      prompt "confirm password \"$OLD_ELASTIC_PASS\""
      res=$?
    done
  fi

  if [ "$selfsignedyn" == "y" ]; then
    #make certs
    generateCA
    generatelogstashcert
    generateclientcert
    generateelasticcert
    generatekibanacert
  elif [ "$selfsignedyn" == "n" ]; then
    echo "Please make sure you have the following certificates named correctly"
    echo "./certs/root-ca.crt"
    echo "./certs/elasticsearch.key"
    echo "./certs/elasticsearch.crt"
    echo "./certs/logstash.crt"
    echo "./certs/logstash.key"
    echo "./certs/kibana.crt"
    echo "./certs/kibana.key"
    echo -e "\e[32m[X]\e[0m Checking for root-ca.crt"
    if [ ! -f ./certs/root-ca.crt ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
    echo -e "\e[32m[X]\e[0m Checking for elasticsearch.key"
    if [ ! -f ./certs/elasticsearch.key ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
    echo -e "\e[32m[X]\e[0m Checking for elasticsearch.crt"
    if [ ! -f ./certs/elasticsearch.crt ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
    echo -e "\e[32m[X]\e[0m Checking for logstash.crt"
    if [ ! -f ./certs/logstash.crt ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
    echo -e "\e[32m[X]\e[0m Checking for logstash.key"
    if [ ! -f ./certs/logstash.key ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
    echo -e "\e[32m[X]\e[0m Checking for kibana.crt"
    if [ ! -f ./certs/kibana.crt ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
    echo -e "\e[32m[X]\e[0m Checking for kibana.key"
    if [ ! -f ./certs/kibana.key ]; then
      echo -e "\e[31m[!]\e[0m File not found!"
      exit 1
    fi
  else
    echo "Not a valid option"
  fi

   
  if [ "$skipdinstall" == "n" ]; then
    installdocker
  fi

  initdockerswarm
  populatecerts
  generatepasswords
  populatelogstashconfig
  configuredocker
  deploylme
  setpasswords
  configelasticsearch
  zipfiles

  #pipelines
  pipelineupdate

  #ILM
  data_retention

  #index mapping
  indexmappingupdate

  #bootstrap
  bootstrapindex

  #create config file
  writeconfig

  #dashboard upload
  uploaddashboards

  #prompt user to enable auto update
  #Deprecated
  #promptupdate
  
  #fix readability: 
  fixreadability

  echo ""
  echo "##################################################################################"
  echo "## Kibana/Elasticsearch Credentials are (these will not be accessible again!)"
  echo "##"
  echo "## Web Interface login:"
  echo "## elastic:$elastic_user_pass"
  echo "##"
  echo "## System Credentials"
  echo "## kibana:$kibana_system_pass"
  echo "## logstash_system:$logstash_system_pass"
  echo "## logstash_writer:$logstash_writer"
  echo "## dashboard_update:$update_user_pass"
  echo "##################################################################################"
  echo ""
}

function uninstall() {
  echo -e "Performs the following:\n\t-kill all container processes\n\t-remove certs from docker"
  read -e -p "Proceed ([y]es/[n]o):" -i "n" check
  if [ "$check" == "n" ]; then
    return
  elif [ "$check" == "y" ];then
    echo -e "\e[32m[X]\e[0m Removing Docker stack and configuration"
    docker stack rm lme
    docker secret rm ca.crt logstash.crt logstash.key elasticsearch.key elasticsearch.crt
    docker secret rm kibana.crt kibana.key
    docker config rm logstash.conf logstash_custom.conf
    echo -e "\e[32m[X]\e[0m Attempting to remove legacy LME files (this will cause expected errors if these no longer exist)"
    docker secret rm winlogbeat.crt winlogbeat.key nginx.crt nginx.key
    docker config rm osmap.csv
    echo -e "\e[32m[X]\e[0m Leaving Docker swarm"
    docker swarm leave --force
    echo -e "\e[32m[X]\e[0m Removing LME config files and configured auto-updates"
    rm -r certs
    crontab -l | sed -E '/lme_update.sh|dashboard_update.sh/d' | crontab -
    echo -e "\e[33m[!]\e[0m NOTICE!"
    echo -e "\e[33m[!]\e[0m No data has been deleted:"
    echo -e "\e[33m[!]\e[0m - Run 'sudo docker volume rm lme_esdata' to delete the elasticsearch database"
    echo -e "\e[33m[!]\e[0m - Run 'sudo docker volume rm lme_logstashdata' to delete the logstash data directory"
    return
  else
    echo -e "\e[33m[!]\e[0m ONLY PROVIDE y or n"
  fi
}

function upgrade() {

  #remove auto updates
  crontab -l | sed -E '/lme_update.sh|dashboard_update.sh/d' | crontab -

  #grab latest version
  latest="1.0"

  #check if the config file we're now creating on new installs exists
  if [ -r /opt/lme/lme.conf ]; then
    #reference this file as a source
    . /opt/lme/lme.conf
    #check if the version number is equal to the one we want
    if [ "$version" == "0.5.1" ]; then
      echo -e "\e[32m[X]\e[0m Updating from git repo"
      git -C /opt/lme/ pull

      echo -e "\e[32m[X]\e[0m Removing existing Docker stack"
      docker stack rm lme
      docker config rm logstash.conf logstash_custom.conf
      echo -e "\e[32m[X]\e[0m Attempting to remove legacy LME files (this will cause expected errors if these no longer exist)"
      docker config rm osmap.csv

      echo -e "\e[32m[X]\e[0m Sleeping for one minute to allow Docker actions to complete..."
      sleep 1m

      #Update Logstash Config
      echo -e "\e[32m[X]\e[0m Updating current configuration files"
      # mv old config to .old
      mv /opt/lme/Chapter\ 3\ Files/logstash.edited.conf /opt/lme/Chapter\ 3\ Files/logstash.edited.conf.old
      # copy new git version
      cp /opt/lme/Chapter\ 3\ Files/logstash.conf /opt/lme/Chapter\ 3\ Files/logstash.edited.conf
      # copy pass from old config into var
      Logstash_Config_Pass="$(awk '{if(/password/) print $3}' </opt/lme/Chapter\ 3\ Files/logstash.edited.conf.old | head -1 | tr -d \")"
      # Insert var into new config
      sed -i "s/insertlogstashwriterpasswordhere/$Logstash_Config_Pass/g" /opt/lme/Chapter\ 3\ Files/logstash.edited.conf
      # delete old config
      rm /opt/lme/Chapter\ 3\ Files/logstash.edited.conf.old

      #Update Docker Config
      #Move old docker config to .old
      mv /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml.old
      #copy new git version
      cp /opt/lme/Chapter\ 3\ Files/docker-compose-stack.yml /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
      # copy ramcount into var
      Ram_from_conf="$(grep -P -o "(?<=Xms)\d+" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml.old)"
      # update Config file with ramcount
      sed -i "s/ram-count/$Ram_from_conf/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
      # copy elastic pass into var
      Kibanapass_from_conf="$(grep -P -o "(?<=ELASTICSEARCH_PASSWORD: ).*" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml.old)"
      #update config with kibana password
      sed -i "s/insertkibanapasswordhere/$Kibanapass_from_conf/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
      #copy kibana encryption key
      kibanakey="$(grep -P -o "(?<=XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY: ).*" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml.old)"
      #update config with kibana key
      sed -i "s/kibanakey/$kibanakey/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
      # copy publicbaseurl
      baseurl_from_conf="$(grep -P -o "(?<=SERVER_PUBLICBASEURL: ).*" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml.old)"
      #update config with publicbaseurl
      if [ -n "$baseurl_from_conf" ] && [ "$baseurl_from_conf" != "insertpublicurlhere" ]; then
        sed -i "s,insertpublicurlhere,$baseurl_from_conf,g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
      elif [ -n "$hostname" ]; then
        sed -i "s/insertpublicurlhere/https:\/\/$hostname/g" /opt/lme/Chapter\ 3\ Files/docker-compose-stack-live.yml
      fi

      customlogstashconf

      echo -e "\e[32m[X]\e[0m Recreating Docker stack"
      docker config create logstash.conf /opt/lme/Chapter\ 3\ Files/logstash.edited.conf
      docker config create logstash_custom.conf /opt/lme/Chapter\ 3\ Files/logstash_custom.conf
      deploylme
      if [ -z "$logstashcn" ]; then
        read -e -p "Enter the Fully Qualified Domain Name (FQDN) of this Linux server: " logstashcn
      fi
      zipfiles
      fixreadability

    elif [ "$version" == $latest ]; then
       echo -e "\e[32m[X]\e[0m You're on the latest version!"
    else
      echo -e "\e[31m[!]\e[0m Updating directly to LME 1.0 from versions prior to 0.5.1 is not supported. Update to 0.5.1 first."
    fi
  fi
}

function renew() {
  #get interface name of default route
  DEFAULT_IF="$(route | grep '^default' | grep -o '[^ ]*$')"

  #get ip of the interface
  EXT_IP="$(/sbin/ifconfig "$DEFAULT_IF" | awk -F ' *|:' '/inet /{print $3}')"
  read -e -p "Enter the IP of this Linux server: " -i "$EXT_IP" logstaship

  #get the FQDN
  read -e -p "Enter the Fully Qualified Domain Name (FQDN) of this Linux server. This needs to be resolvable from the Windows Event Collector: " logstashcn
  echo -e "\e[32m[X]\e[0m Configuring certificates to use $logstaship as the IP and $logstashcn as the DNS"

  echo -e "\e[32m[X]\e[0m Removing existing Docker stack"
  docker stack rm lme
  removecerts

  read -e -p "Do you want to regenerate the root Certificate Authority (warning - this will invalidate all current certificates in use) ([y]es/[n]o): " -i "n" regen_CA
  if [ "$regen_CA" == "y" ]; then
    generateCA
    generatelogstashcert
    generateelasticcert
    generatekibanacert
    generateclientcert
    zipnewcerts
  elif [ "$regen_CA" == "n" ]; then
    read -e -p "Do you want to regenerate the Logstash certificate ([y]es/[n]o): " -i "n" regen_logstash
    if [ "$regen_logstash" == "y" ]; then
      generatelogstashcert
    fi
    read -e -p "Do you want to regenerate the Elasticsearch certificate ([y]es/[n]o): " -i "n" regen_elastic
    if [ "$regen_elastic" == "y" ]; then
      generateelasticcert
    fi
    read -e -p "Do you want to regenerate the Kibana certificate ([y]es/[n]o): " -i "n" regen_kibana
    if [ "$regen_kibana" == "y" ]; then
      generatekibanacert
    fi
    read -e -p "Do you want to regenerate the Winlogbeat client certificate (warning - you will need to re-install Winlogbeat with the new certificate on the WEC server if you do this) ([y]es/[n]o): " -i "n" regen_client_cert
    if [ "$regen_client_cert" == "y" ]; then
      generateclientcert
      zipnewcerts
    fi
  else
    echo "Not a valid option, re-adding existing certificates and exiting"
  fi

  populatecerts
  echo -e "\e[32m[X]\e[0m Recreating Docker stack"
  deploylme
}

function usage(){
  echo -e "\e[31m[!]\e[0m Invalid operation specified"
  echo "Usage:    ./deploy.sh (install/uninstall/renew/upgrade/update)"
  echo "Example:  ./deploy.sh install"
  exit 1
}

############
#START HERE#
############
export CERT_STRING='/C=US/ST=DC/L=Washington/O=CISA'

#Check the script has the correct permissions to run
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\e[31m[!]\e[0m This script must be run with root privileges"
  exit 1
fi

#Check the install location
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
if [[ "$DIR" != "/opt/lme/Chapter 3 Files" ]]; then
  echo -e "\e[31m[!]\e[0m The deploy script is not currently within the correct path, please ensure that LME is located in /opt/lme for installation"
  exit 1
fi

#Change current working directory so relative filepaths work
cd "$DIR" || exit

#What action is the user wanting to perform
if [ "$1" == "" ]; then
  usage
elif [ "$1" == "install" ]; then
  install
elif [ "$1" == "uninstall" ]; then
  uninstall
elif [ "$1" == "upgrade" ]; then
  upgrade
elif [ "$1" == "renew" ]; then
  renew
elif [ "$1" == "update" ]; then
  update
else
  usage
fi
