---
title: JVM调优系列之处理内存报警
toc: true
date: 2020-01-10 18:02:30
author: GSM
tags:
  - JVM
categories: 业务实践
article-thumbnail: false
---
服务又收到报警了系列。
<!--more-->
某日服务收到内存报警： 
```
状态:P3故障
名称:mem.used.percent大于85%
指标:mem.used.percent
主机:sec-upm-data-analysis-sf-42851-0.docker.py
节点:hnc-v.upm-data-analysis.upm.sec.sec.didi.com
当前值:92.01
说明:happen(mem.used.percent,#60,60) >90
故障时间:2020-01-10 16:49:20
详情: http://monitor.xiaojukeji.com/#/odin/alarm/event/373081480
```

一个服务机器（4Core 4G）内存达到了92%。看了下近几天的监控，机器内存持续升高。现场监控图如下：
![](monitor.jpg)

本能反应看下top:
![](top.png)
发现4G docker, 我们的java服务已经占据了2.321G, 再加上docker里还跑着监控服务和日志服务，很容易服务达到3G+的内存。

再看JVM堆内存使用分布：
```
jmap -heap 970
```
![](jmap.png)

这里发现一个很奇怪的地方MaxHeapSize 竟然近30G，而docker的内存只是4G，说明JVM对堆的内存并没有进行实际限制。我们知道Xmx 默认值是物理内存的1/4（宿主机128G），由此怀疑我们的Java服务很可能没有配置XMX。排查代码，果然如此。

遂增加配置：
```
-Xmx2g -Xms2g
```


---
其他JVM文章：
1. [频繁Full GC引起的服务雪崩](https://gsmtoday.github.io/2018/10/15/%E6%8E%A5%E5%8F%A3%E8%B6%85%E6%97%B6%E5%BC%95%E8%B5%B7%E7%B3%BB%E7%BB%9F%E9%9B%AA%E5%B4%A9%E5%8E%9F%E5%9B%A0%E5%8F%8D%E6%80%9D/)

2. [JVM调试工具入门](https://gsmtoday.github.io/2016/10/17/jvm-debug/)



























