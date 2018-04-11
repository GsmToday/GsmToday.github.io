---
title: RocketMQ源码分析6--Client之Producer模块
toc: true
banner: /images/rabbit.jpeg
date: 2018-04-21 15:38:39
author: GSM
tags:
  - RocketMQ
categories: 消息队列
---

本文是[RocketMQ源码分析系列](https://gsmtoday.github.io/tags/RocketMQ/)之六，如有疑问或者技术探讨，可以[email me](gsmuestc@163.com),欢迎探讨.

<!-- more -->
RocketMQ中Producer由用户部署，消息由Producer通过多种负载均衡模式发送到Broker集群，发送低延时，支持failfast.