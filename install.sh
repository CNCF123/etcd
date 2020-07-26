#!/bin/bash

#集群信息
#192.168.0.101 etcd01
#192.168.0.102 etcd02
#192.168.0.103 etcd03

# 安装cfssl
curl -s -L -o /bin/cfssl https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
curl -s -L -o /bin/cfssljson https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
curl -s -L -o /bin/cfssl-certinfo https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x /bin/cfssl*


#创建文件夹
mkdir -p /home/etcd/ssl
cd /home/etcd/ssl

#创建 CA 配置文件（ca-config.json）
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "www": {
         "expiry": "87600h",
         "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ]
      }
    }
  }
}
EOF

#"字段说明"
#"ca-config.json"：可以定义多个 profiles，分别指定不同的过期时间、使用场景等参数；后续在签名证书时使用某个 profile；
#"signing"：表示该证书可用于签名其它证书；生成的 ca.pem 证书中 CA=TRUE；
#"server auth"：表示client可以用该 CA 对server提供的证书进行验证；
#"client auth"：表示server可以用该CA对client提供的证书进行验证；


创建 CA 证书签名请求（ca-csr.json）
cat > ca-csr.json <<EOF
{
    "CN": "etcd",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "Shanghai",
            "ST": "Shanghai",
            "O": "etcd",
            "OU": "System"
        }
    ]
}
EOF

#"CN"：Common Name，etcd 从证书中提取该字段作为请求的用户名 (User Name)；浏览器使用该字段验证网站是否合法；
#"O"：Organization，etcd 从证书中提取该字段作为请求用户所属的组 (Group)；
#这两个参数在后面的kubernetes启用RBAC模式中很重要，因为需要设置kubelet、admin等角色权限，那么在配置证书的时候就必须配置对了，具体后面在部署kubernetes的时候会进行讲解。
#"在etcd这两个参数没太大的重要意义，跟着配置就好。"


#生成 CA 证书和私钥
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

#说明：生成 "ca-key.pem  ca.pem" 2个文件


#创建 etcd证书签名请求（etcd-csr.json）
cat > etcd-csr.json <<EOF
{
    "CN": "etcd",
    "hosts": [
    "192.168.0.101",
    "192.168.0.102",
    "192.168.0.103"
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "Shanghai",
            "ST": "Shanghai",
            "O": "etcd",
            "OU": "System"
        }
    ]
}
EOF

#修改配置文件，注意，注意，注意把集群的ip列表加到etcd-csr.json中的hosts


#生成 etcd证书和私钥 
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=etcd etcd-csr.json | cfssljson -bare etcd

#生成 "etcd-key.pem  etcd.pem" 2个文件。

#将TLS 认证文件拷贝至证书目录下
mkdir -p /etc/etcd/etcdSSL
cp * /etc/etcd/etcdSSL


#安装etcd
yum -y install etcd


#编辑配置文件etcd.conf
#https://github.com/CNCF123/etcd/blob/master/etcd.conf

cat > /etc/etcd/etcd.conf <<EOF
#[Member]
ETCD_NAME="etcd01"   ### 每个节点不一样
ETCD_DATA_DIR="/var/lib/etcd/"
ETCD_LISTEN_PEER_URLS="https://192.168.0.101:2380"    #改成当前服务器的ip
ETCD_LISTEN_CLIENT_URLS="https://192.168.0.101:2379"  #改成当前服务器的ip

#[Clustering]
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://192.168.0.101:2380"
ETCD_ADVERTISE_CLIENT_URLS="https://192.168.0.101:2379"
ETCD_INITIAL_CLUSTER="etcd01=https://192.168.0.101:2380,etcd02=https://192.168.0.102:2380,etcd03=https://192.168.0.103:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"

ETCD_AUTO_TLS="true"
ETCD_PEER_AUTO_TLS="true"
ETCD_PEER_CLIENT_CERT_AUTH="true"

EOF

#编辑配置文件etcd.service
#https://github.com/CNCF123/etcd/blob/master/etcd.service

cat /usr/lib/systemd/system/etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
EnvironmentFile=-/etc/etcd/etcd.conf
User=etcd
#set GOMAXPROCS to number of processors
ExecStart=/usr/bin/etcd \
--name=${ETCD_NAME} \
--data-dir=${ETCD_DATA_DIR}\
--listen-peer-urls=${ETCD_LISTEN_PEER_URLS} \
--listen-client-urls=${ETCD_LISTEN_CLIENT_URLS},https://127.0.0.1:2379 \
--advertise-client-urls=${ETCD_ADVERTISE_CLIENT_URLS} \
--initial-advertise-peer-urls=${ETCD_INITIAL_ADVERTISE_PEER_URLS} \
--initial-cluster=${ETCD_INITIAL_CLUSTER} \
--initial-cluster-token=${ETCD_INITIAL_CLUSTER_TOKEN} \
--initial-cluster-state=${ETCD_INITIAL_CLUSTER_STATE} \
--cert-file=/etc/etcd/etcdSSL/etcd.pem \
--key-file=/etc/etcd/etcdSSL/etcd-key.pem \
--peer-cert-file=/etc/etcd/etcdSSL/etcd.pem \
--peer-key-file=/home/etcd/ssl/server-key.pem \
--trusted-ca-file=/etc/etcd/etcdSSL/ca.pem \
--peer-trusted-ca-file=/etc/etcd/etcdSSL/ca.pem

Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target

EOF


#启动
#启动前需要将其他节点配置文件和ssl文件等都复制到其他节点，然后一起启动

#systemctl start etcd