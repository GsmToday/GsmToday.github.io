---
title: Spring项目加载慢问题
toc: false
thumbnail: /images/woniu.jpg
date: 2017-08-23 20:42:59
author: GSM
tags:
  - Spring
---

最近遇到一个诡异的问题，项目启动异常缓慢(每次重启tomcat都要6-7分钟)，这对于开发来说简直是灾难式体验，所以决心修正此问题。

首先google搜索解决tomcat启动慢的问题，按照大多数人反映的计算熵SecureRandom的方法修改，发现无效。于是只好阅读tomcat启动日志，发现每次项目启动，时间都卡在这里` org.apache.catalina.core.ApplicationContext.log Initializing Spring root WebApplicationContext`。这时候搜索结果就与计算熵SecureRandom无关了，而是spring启动的问题，摘取排查问题步骤如下，果然解决。
<!-- more -->

1. 检查spring是否运行在debug模式下，是跳转到2 否则跳转到3
2. 查看spring在run模式下是否运行依旧缓慢 是跳转到3，否则跳转到4
3. 检验是否spring bean加载了多次（quartz加载很有可能导致部分bean被是实例两次） [是跳转到](http://blog.csdn.net/chaijunkun/article/details/6925889); 否则[跳转到](http://jinnianshilongnian.iteye.com/blog/1883013)
4. 请将代码中所有代码断点禁用掉或者全部删除重新进入到debug模式下查看加载速度是否变快 .

发现debug模式下可能导致应用启动速度大幅度变慢。将breakpoint删除后我的应用从 171021ms+43824 ms=====》13021ms+2950ms

我使用Step4就解决了项目启动慢的问题，原来是打了太多断点，影响了加载速度...
