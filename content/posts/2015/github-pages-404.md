---
title: "用 github pages搭建静态博客 404 解决办法"
date: 2015-01-07T15:46:26+08:00
tags: ["others"]
categories: ["others"] 
draft: false 
---


  博客很久都没更新了，因为之前重装系统之后，重新配置了一下博客，结果一直404。最近用重新尝试了一下，终于搞定了。在网上发现不少人在按照各种教程用HEXO或者JekyII配置博客之后,博客仍然无法访问，这里把问题可能的原因和解决办法总结一下。
  
  <!--more-->
  - github pages 生成可能需要一点时间，大概是10分钟到半小时，期间访问页面会404
   + 解决办法：喝杯茶，just wait。
  - 如果之前有已经搭建了博客，或者在本地测试页面能够访问，那么可能是缓存的原因
      + 解决办法：刷新页面或者清空缓存
  - 自己申请了域名用CNAME解析的话，可以ping通github 的二级域名而ping不通自己的域名
   + 解决办法：域名解析可能需要一段时间，如果不行删除CNAME或者检查CNAME内容是否正确（注意CNAME不能有后缀）
  - 用户名大小问题
   + 解决办法：检查用户名大小写是否出错，或者换个全是小写的github账号
  - repo的名字是xxx.github.com
   + 解决办法：改成xxx.github.io即可
  - 以上解决方案依然无法解决
   + 解决办法：先备份博客，打开项目的setting，点击 Automatic page generator,先使用自带的功能创建github pages,然后打开 username.github.io,确认可以访问了以后,clone 项目后,删除已有文件,替换你自己的博客
  - 还是无法解决
   + 可能是网络原因或者伟大的GFW的问题，可以咨询Github客服