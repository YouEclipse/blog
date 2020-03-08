---
title: "用 github pages搭建静态博客 404 解决办法"
date: 2015-04-19T19:56:46+08:00
tags: ["html","javascript"]
categories: ["javascript"]
draft: false
---


我们上网时经常能遇到各种抽奖，转盘抽奖是我们比较常见的一种方式，那么这是怎么实现的呢？让我们一探究竟。
<!--more-->
![](http://wuchuiyou.qiniudn.com/2015-4-19抽奖.png)

如上图，我们可以分析，整个转盘其实就是一个大的盒子里面包裹着几个小盒子，中间的按钮我们可以用a标签，那么我们可以先把它界面大致写出来

```html
	<div class="mainBox" id="main">
		<div id="i1">1</div>
		<div id="i2">2</div>
		<div id="i3">3</div>
		<div id="i4">4</div>
		<div id="i5">5</div>
		<div id="i6">6</div>
		<div id="i7">7</div>
		<div id="i8">8</div>
		<div id="i9">9</div>
		<div id="i10">10</div>
		<div id="i11">11</div>
		<div id="i12">12</div>
		<div id="i13">13</div>
		<div id="i14">14</div>
		<a>开始</a>
	</div>
```

然后加上点Css样式
```
.mainBox {
	width:530px;
	height:425px;
	background: #CCC;
	margin: 0 auto;
	position: relative; 
}

.mainBox div{ 
	width:100px; 
	height:100px; 
	background:#fff; 
	position:absolute; 
	font:50px/100px "微软雅黑"; 
	color:#000; text-align:center;
	box-sizing:border-box;
}

#i1{top:5px;left: 5px;}
#i2{top:5px;left: 110px;}
#i3{top:5px;left: 215px;}
#i4{top:5px;left: 320px;}
#i5{top:5px;left: 425px;}
#i6{top:110px;left: 425px;}
#i7{top:215px;left: 425px;}
#i8{top:320px;left: 425px;}
#i9{top:320px;left: 320px;}
#i10{top:320px;left: 215px;}
#i11{top:320px;left: 110px;}
#i12{top:320px;left: 5px;}
#i13{top:215px;left: 5px;}
#i14{top:110px;left: 5px;}

.bottonCss{
	display: block;
	width: 310px;
	height: 205px;
	background: #F60;
	text-decoration: none;
	text-align: center;
	font: 50px/205px "微软雅黑";
	position: absolute;
	left: 110px;
	top:110px;
	color: #000;
}
.mainBox .curCss{
	background: #0f0;
	border:5px solid #C30;
}
.bottonCss:hover{
 	border:5px solid #C30; 
	background:#0f0; 
	box-sizing:border-box;
}
```

![](http://wuchuiyou.qiniudn.com/2015-4-191.png)
如图，我们可以看到转盘的样式我们已经完成了，那么我们分析一下js代码改如何实现呢？

我们知道，我们可以用js改变ClassName属性来改变Css样式，那么我们是不是可以用setInterval动态地改变CSS样式来做出轮盘转动的效果呢？我们可以尝试一下。
我们首先将改变CSS样式的方法实现，原理很简单，每个小事件就是清除前一个的CSS样式，同时改变当前的CSS样式
```
var curNum;//先定义一个变量来记录当前位置
function draw () {
	curNum++;
	//清除前一个的Css样式，然后更新当前的样式
	divs[curNum-1].className = "";
	divs[curNum].className = "curCss";

}
```

但是这么做似乎会有点小问题，当到了最后一个时，它似乎就停了
那么我们再处理下细节
```
function draw () {
	curNum++;
	if(curNum==14){
		//当到了最后一个时，令curNum重新等于0
		divs[curNum-1].className = "";
		curNum=0;
		divs[curNum].className = "curCss";
	}else{
		//清除前一个的Css样式，然后更新当前的样式
		divs[curNum-1].className = "";
		divs[curNum].className = "curCss";
	}
}
```
这样似乎是没问题了。
接下来要给开始按钮添加一个startDraw()触发事件

```
<a class="bottonCss" href="javascript:startDraw()">开始</a>
```

然后在startDraw()里面用启动定时器来改变Css样式
```
function startDraw() {
	startEvt=window.setInterval(draw,100);
}
```
现在我们可以跑一下试一下了，可是我们发现它是从2开始，似乎我们开始的算法有点小问题，没事，我们可以在startDraw（）中开启定时器之前初始化下第一个小方块
```
divs[0].className = "curCss";

```

好，现在我们可以在浏览器打开页面看一下效果，发现它根本停不下来

那我们就让他停下来吧。
我们再增加一个变量circleNum用来统计圈数
```
var circleNum=0;
var totalBox=divs.length;
```
增加一个随机数randNum（0~13），随机数就是最后中奖的停止的位置。
```
var randNum=Math.ceil(Math.random()*totalBox);
```
然后在draw（）里面添加以下代码，在转完3圈之后停下来
```

if(circleNum==(totalBox*3+randNum)){
		window.clearInterval(startEvt);
		alert("你抽中了"+(randNum+1)+"!");
}
```
这么轮盘抽奖的程序就大致完成了，如图
![](http://wuchuiyou.qiniudn.com/2015-4-192.png)

我们还可以再完善以下，一般的轮盘抽奖程序都是从慢到快再逐渐慢下来，我们也可以增加两个标志位来加速和减速

```
var speedPoint=6;
var slowPoint=6;
```
然后同样，在draw函数中，通过删除原来的定时器，设置新的定时器来完成加速和减速

```
if(circleNum==speedPoint){
	window.clearInterval(startEvt);
	startEvt=window.setInterval(draw,100/3);
}
if(circleNum==(totalBox*3+randNum-slowPoint)){
	window.clearInterval(startEvt);
	startEvt=window.setInterval(draw,100*3);
}
```
至此，一个js轮盘抽奖程序就完成了，总体的思路就是通过动态的改变每个盒子的样式来实现一个抽奖的效果。把全部js代码整理下如下：
```
<script type="text/javascript">
	var mainBox=document.getElementById("main");
	var divs=main.getElementsByTagName("div");//通过大的div获取到每个小方块
	var curNum;//小方块的位置
	var circleNum;
	var speedPoint=6;
	var slowPoint=6;
	var totalBox;
	var randNum=Math.ceil(Math.random()*totalBox);
	function draw () {
		curNum++;
		circleNum++;
		if(curNum==14){
			//当到了最后一个时，令curNum重新等于0
			divs[curNum-1].className = "";
			curNum=0;
			divs[curNum].className = "curCss";
		}else{
			//清除前一个的Css样式，然后更新当前的样式
			divs[curNum-1].className = "";
			divs[curNum].className = "curCss";
		}
		if(circleNum==speedPoint){
			window.clearInterval(startEvt);
			startEvt=window.setInterval(draw,100/3);
		}
		if(circleNum==(totalBox*3+randNum-slowPoint)){
			window.clearInterval(startEvt);
			startEvt=window.setInterval(draw,100*3);
		}
		if(circleNum==(totalBox*3+randNum)){
			window.clearInterval(startEvt);
			alert("你抽中了"+(randNum+1)+"!");
		}
	}

	function startDraw() {
		curNum=0;//小方块的位置
		circleNum=0;
		totalBox=divs.length;
		randNum=Math.ceil(Math.random()*totalBox);
		divs[0].className = "curCss";
		startEvt=window.setInterval(draw,100);
	}

	</script>
```
