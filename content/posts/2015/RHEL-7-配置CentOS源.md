---
title: "RHEL 7 配置CentOS源"
date: 2015-05-02T21:15:26+08:00
tags: ["linux","centos"]
categories: ["linux"]
draft: false
---

###安装EPEL
下载EPEL RPM安装包，目前最新的版本是epel-release-7-5.noarch.rpm，如果链接无效，可以在<http://dl.fedoraproject.org/pub/epel/7/x86_64/e/>找到对应的rpm包即可

<!--more-->
下载
```
wget http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
```
安装
```
yum install epel-release-7-5.noarch.rpm
```

查看是否安装成功
```
yum repolist
```

###redhat配置centos源

```
vim /etc/yum.repos.d/CentOS-Base.repo
```

将一下内容复制到文件中

```
[base]

name=CentOS-5-Base

#mirrorlist=http://mirrorlist.centos.org/?release=$releasever5&arch=$basearch&repo=os

#baseurl=http://mirror.centos.org/centos/$releasever/os/$basearch/

baseurl=http://ftp.sjtu.edu.cn/centos/7/os/$basearch/

gpgcheck=0

gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

#released updates

[updates]

name=CentOS-$releasever – Updates

#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=updates

baseurl=http://ftp.sjtu.edu.cn/centos/7/updates/$basearch/

gpgcheck=0

gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[extras]

name=CentOS-$releasever – Extras

#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=extras

baseurl=http://ftp.sjtu.edu.cn/centos/7/extras/$basearch/

gpgcheck=0

gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[centosplus]

name=CentOS-$releasever – Plus

#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=centosplus

baseurl=http://ftp.sjtu.edu.cn/centos/7/centosplus/$basearch/

gpgcheck=0

enabled=0

gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
```
执行以下命令
```
rpm --import http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7
rpm -qa gpg-pubkey
```
