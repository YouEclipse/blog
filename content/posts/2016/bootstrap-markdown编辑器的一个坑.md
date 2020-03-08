---
title: "bootstrap-markdown编辑器的一个坑"
date: 2016-04-19T23:49:18+08:00
tags: ["markdown"]
categories: ["javascript"]
draft: false
---


前段时间突然有个妹纸加我扣扣，受宠若惊。后来才知道是之前自己在Yii论坛发过个关于BootStrap-Markdown编辑器使用的帖子，她用这个编辑器的时候遇到了问题，就是在引入编辑器后无法预览，然后想起来自己当初也遇到了这个坑。
<!--more-->
BootStrap-Markdown 编辑器应该是目前来说比较好用的markdown富文本编辑器，其中提供了预览功能，但是不注意看文档可能会忽略文档最下面的说明，如图

![](http://7lrwkx.com1.z0.glb.clouddn.com/bootstrap-markdown.png)，需要添加markdown.js和to-markdown.js这两个依赖， 但是按照官方给的链接，markdown.js的链接似乎是有问题的，所以会导致无法预览，正确的链接应该是
[http://www.codingdrama.com/bootstrap-markdown/js/markdown.js](http://www.codingdrama.com/bootstrap-markdown/js/markdown.js) ，在项目中添加这个文件，问题即可解决。